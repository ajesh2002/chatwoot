# Chatwoot Architecture Audit

**Repository:** `ajesh2002/chatwoot`
**Audited version:** `4.18.0` (`package.json`), Rails app on branch `claude/optimistic-noether-eykrsz`
**Date:** 2026-09-18
**Scope:** Read-only architecture audit. No application code was modified.

This document maps the existing system so that a branded SaaS can be built on top of Chatwoot
without forking the parts that change most often upstream. Every claim below is anchored to a
concrete file path so it can be re-verified.

---

## Table of contents

1. [Overall project structure](#1-overall-project-structure)
2. [Rails backend architecture](#2-rails-backend-architecture)
3. [Frontend architecture](#3-frontend-architecture)
4. [Database models and relationships](#4-database-models-and-relationships)
5. [Authentication and authorization](#5-authentication-and-authorization)
6. [Multi-tenant / workspace architecture](#6-multi-tenant--workspace-architecture)
7. [Conversation / inbox architecture](#7-conversation--inbox-architecture)
8. [Channel architecture](#8-channel-architecture)
9. [WhatsApp integration](#9-whatsapp-integration)
10. [Instagram integration](#10-instagram-integration)
11. [Facebook / Messenger integration](#11-facebook--messenger-integration)
12. [Webhook architecture](#12-webhook-architecture)
13. [Message sending / receiving flow](#13-message-sending--receiving-flow)
14. [Realtime architecture](#14-realtime-architecture)
15. [Background jobs / Sidekiq](#15-background-jobs--sidekiq)
16. [API architecture](#16-api-architecture)
17. [Existing UI component system](#17-existing-ui-component-system)
18. [Existing design system](#18-existing-design-system)
19. [Enterprise directory and licensing boundaries](#19-enterprise-directory-and-licensing-boundaries)
20. [Configuration / environment setup](#20-configuration--environment-setup)
21. [Key narratives](#21-key-narratives) — message in, message to UI, agent send, channel connect, tenant isolation
22. [Reuse / customize / avoid](#22-reuse--customize--avoid)
23. [Safest extension points for a branded SaaS](#23-safest-extension-points-for-a-branded-saas)

---

## 1. Overall project structure

Chatwoot is a **Rails 7.x monolith** that serves a **Vue 3 SPA** (plus an embeddable widget SDK)
through Vite. It is a single deployable with two process types.

| Path | Purpose |
|---|---|
| `app/` | Rails MVC plus Chatwoot-specific layers: `builders/`, `services/`, `listeners/`, `dispatchers/`, `jobs/`, `policies/`, `finders/`, `presenters/`, `drops/` |
| `app/javascript/` | All frontend code: `dashboard/` (agent SPA), `widget/` (end-user chat), `sdk/` (embed loader), `portal/` (help center), `survey/` (CSAT), `v3/` (new auth/onboarding), `shared/`, `design-system/` |
| `enterprise/` | Enterprise overlay (separate license) — models, controllers, services, jobs that extend or override OSS code |
| `lib/` | Non-Rails-autoloaded support: `integrations/`, `captain/` (AI), `webhooks/`, `redis/`, `global_config.rb`, `chatwoot_app.rb` |
| `config/` | `routes.rb` (780 lines), `features.yml` (142 feature flags), `installation_config.yml`, `sidekiq.yml`, `schedule.yml`, `initializers/` |
| `db/` | `schema.rb` (~95 tables), 180 migrations |
| `swagger/` | OpenAPI 3.1 source for the public API (`swagger/swagger.json`, split sources under `paths/`, `definitions/`) |
| `spec/` | RSpec suite, mirrored under `spec/enterprise/` for EE |
| `public/` | Compiled assets, brand assets (`public/brand-assets/`), widget bundles |
| `theme/` | `colors.js` / `icons.js` consumed by `tailwind.config.js` |
| `docker/`, `deployment/`, `Procfile*` | Deployment orchestration |

Process model (`Procfile`):
- `web` — Rails/Puma (HTTP + ActionCable)
- `worker` — Sidekiq

Dev: `Procfile.dev` runs `backend` (rails s), `worker` (sidekiq), `vite` (bin/vite dev).

**Key entry files:**
- `config/routes.rb` — the single source of truth for every HTTP surface
- `config/application.rb`, `config/initializers/00_init.rb`
- `config/initializers/01_inject_enterprise_edition_module.rb` — the EE overlay mechanism
- `config/initializers/event_handlers.rb` — wires the event dispatcher
- `app/javascript/entrypoints/*.js` — one Vite entry per frontend app

---

## 2. Rails backend architecture

Chatwoot layers beyond stock Rails. Understanding these layers is the single most important thing
for extending it safely.

### 2.1 Layer map

```
HTTP request
  └─ Controller (app/controllers/**)          thin; auth, params, policy check
       └─ Builder (app/builders/**)           object construction with side effects
       └─ Service (app/services/**)           business operation, one public #perform
            └─ Model (app/models/**)          persistence + callbacks
                 └─ Dispatcher.dispatch(...)  domain event
                      ├─ SyncDispatcher  → ActionCableListener, AgentBotListener
                      └─ AsyncDispatcher → EventDispatcherJob → 10 listeners
                           └─ Jobs (app/jobs/**) → Sidekiq
```

### 2.2 Controllers

- Base: `app/controllers/application_controller.rb` — includes `DeviseTokenAuth`, `Pundit::Authorization`,
  `RequestExceptionHandler`, `SwitchLocale`, `TrackSessionActivity`. Sets `Current.user`.
- API base: `app/controllers/api/base_controller.rb` — chooses between access-token auth and Devise session.
- Account-scoped base: `app/controllers/api/v1/accounts/base_controller.rb` — includes
  `EnsureCurrentAccountHelper`, forces `current_account` before every action. **This is the tenancy chokepoint.**
- Separate namespaces: `api/v1`, `api/v2` (reports), `platform/api/v1` (instance-level provisioning),
  `public/api/v1` (unauthenticated widget/help-center), `webhooks/*`, `super_admin/*`, `survey/*`.

### 2.3 Services (`app/services/`)

~200 service objects. Convention: `pattr_initialize` + a single `#perform`. The two structural
base classes worth knowing:

- `app/services/base/send_on_channel_service.rb` — **the outbound channel contract.** Subclasses
  implement `channel_class` and `perform_reply`. It validates the channel matches, skips private
  notes, skips messages that originated from the channel (echo-loop guard), and skips `voice_call` bubbles.
- `app/services/filter_service.rb` + `conversations/filter_service.rb`, `contacts/filter_service.rb` —
  the saved-filter / advanced-search query builder.

### 2.4 Builders (`app/builders/`)

Construction with orchestration, used where a plain `create!` isn't enough:

- `app/builders/messages/message_builder.rb` — canonical message creation (attachments, emails, quoting)
- `app/builders/conversation_builder.rb` — reuse-or-create conversation, honours `lock_to_single_conversation`
- `app/builders/contact_inbox_with_contact_builder.rb` — resolves/creates the contact + contact_inbox pair
- `app/builders/messages/{facebook,instagram,messenger}/…` — channel-specific inbound message construction
- `app/builders/account_builder.rb`, `agent_builder.rb` — signup/invite

### 2.5 Event system (`app/dispatchers/`, `app/listeners/`)

`Rails.configuration.dispatcher.dispatch(EVENT, timestamp, payload)` fans out via Wisper.

- `app/dispatchers/dispatcher.rb` — singleton, always dispatches to **both** sync and async
- `app/dispatchers/sync_dispatcher.rb` — `ActionCableListener`, `AgentBotListener` (in-request, low latency)
- `app/dispatchers/async_dispatcher.rb` — enqueues `EventDispatcherJob`, which replays to:
  `AutomationRuleListener`, `CampaignListener`, `CsatSurveyListener`, `HookListener`,
  `InstallationWebhookListener`, `NotificationListener`, `ParticipationListener`,
  `Conversations::UnreadCounts::Listener`, `ReportingEventListener`, `WebhookListener`
- Event names: `lib/events/types.rb` (included as `Events::Types`)
- Both dispatchers are EE-extensible: `SyncDispatcher.prepend_mod_with('SyncDispatcher')`

**This event bus is the single best extension point in the backend** — see §23.

### 2.6 Other layers

- `app/finders/` — query objects (`ConversationFinder`, `MessageFinder`, `NotificationFinder`)
- `app/policies/` — Pundit policies (see §5)
- `app/presenters/`, `app/drops/` — Liquid template exposure for canned responses/campaigns
- `app/mailboxes/` — inbound email routing (ActionMailbox)
- `app/listeners/base_listener.rb` — shared payload extraction helpers

---

## 3. Frontend architecture

Four distinct Vue 3 applications built by Vite, each with its own entrypoint in
`app/javascript/entrypoints/`:

| App | Entry | Purpose |
|---|---|---|
| Dashboard | `dashboard.js` | The agent workspace SPA (the bulk of the code) |
| Widget | `widget.js` | End-user chat window rendered in an iframe |
| SDK | `sdk.js` | Tiny loader script embedded on customer sites (`public/packs/js/sdk.js`, 40 KB budget) |
| Portal | `portal.js` | Public help center |
| Survey | `survey.js` | Standalone CSAT page |
| v3 | `v3app.js` | Newer auth / onboarding shell |
| Superadmin | `superadmin*.js` | Administrate-based instance admin sprinkles |

### 3.1 Dashboard internals (`app/javascript/dashboard/`)

- `routes/` — vue-router, feature-area folders (`conversation/`, `contacts/`, `settings/`, `campaigns/`,
  `helpcenter/`, `captain/`, `reports/`, `inbox/`, `calls/`, `onboarding/`)
- `store/` — **Vuex** (~55 modules under `store/modules/`), the primary state layer
- `stores/` — **Pinia** (`calls.js`, `companies.js`, `callHistory.js`) — the newer, incremental store
- `api/` — one module per resource, all extending `api/ApiClient.js`
- `components/` — legacy components (164 `.vue`)
- `components-next/` — current component system (494 `.vue`) — **this is where new UI goes**
- `composables/` — Composition API helpers (`store.js` → `useMapGetter`, `useAlert`, `useImpersonation`, …)
- `helper/actionCable.js` — the realtime event router
- `i18n/` — locale JSON; only `en.json` is edited by hand (Crowdin owns the rest)
- `featureFlags.js` — mirrors `config/features.yml` names for the UI

### 3.2 API client and account scoping

`app/javascript/dashboard/api/ApiClient.js` derives the account id **from the URL path**:

```js
get accountIdFromRoute() {
  const isInsideAccountScopedURLs = window.location.pathname.includes('/app/accounts');
  if (isInsideAccountScopedURLs) return window.location.pathname.split('/')[3];
  return '';
}
baseUrl() {
  let url = this.apiVersion;                                   // /api/v1
  if (this.options.enterprise) url = `/enterprise${url}`;      // /enterprise/api/v1
  if (this.options.accountScoped && this.accountIdFromRoute)
    url = `${url}/accounts/${this.accountIdFromRoute}`;
  return url;
}
```

So every dashboard URL is `/app/accounts/:account_id/...` and every API call becomes
`/api/v1/accounts/:account_id/...`. **Account scoping is structural, not incidental.**

### 3.3 Conventions enforced by `CLAUDE.md` / `AGENTS.md`

- Composition API with `<script setup>` at the top of every component
- PascalCase components, camelCase events
- **Tailwind only** — no custom CSS, no scoped CSS, no inline styles
- No bare strings in templates; everything through vue-i18n
- New message-bubble UI belongs in `components-next/` (the rest is being deprecated)
- Logical Tailwind utilities (`ms`, `me`, `start`, `end`) for RTL support

---

## 4. Database models and relationships

PostgreSQL. `db/schema.rb` is ~1,636 lines, ~95 tables, 180 migrations. Models carry annotated
schema comments (`.annotaterb.yml`).

### 4.1 Core graph

```
Account (tenant root)
 ├─ AccountUser ── User                    (membership + role)
 ├─ Inbox ── Channel::* (polymorphic)      (one inbox per channel record)
 │    ├─ InboxMember ── User               (agent access)
 │    ├─ AgentBotInbox ── AgentBot
 │    └─ ContactInbox ── Contact           (identity of a contact ON an inbox, has source_id)
 │         └─ Conversation
 │              ├─ Message ── Attachment
 │              ├─ ConversationParticipant
 │              ├─ Mention
 │              └─ CsatSurveyResponse
 ├─ Contact ── ContactInbox
 ├─ Team ── TeamMember
 ├─ Label (acts_as_taggable_on)
 ├─ AutomationRule / Macro / CannedResponse / Campaign
 ├─ Portal ── Category ── Article          (help center)
 ├─ Webhook, Integrations::Hook
 └─ CustomAttributeDefinition, CustomFilter, DashboardApp, Notification*
```

### 4.2 The four tables that matter most

**`accounts`** (`app/models/account.rb`) — the tenant. ~40 `has_many … dependent: :destroy_async`.
Carries `feature_flags` + `feature_flags_ext_1` bitsets (FlagShihTzu), a `settings` jsonb with a
JSON-schema validator (`AccountSettingsSchema`), `limits` jsonb, `custom_attributes`, `status`
(active/suspended). A Postgres trigger creates a per-account sequence `conv_dpid_seq_<id>` so
conversation `display_id` is per-tenant.

**`inboxes`** (`app/models/inbox.rb`) — `belongs_to :channel, polymorphic: true, dependent: :destroy`.
The inbox is the **channel-agnostic façade**: name, avatar, greeting, working hours, CSAT config,
auto-assignment config, `lock_to_single_conversation`. Exposes predicate helpers (`whatsapp?`,
`instagram?`, `facebook?`, `email?`, `api?`, `web_widget?`, `twilio_whatsapp?`) that the rest of the
codebase branches on.

**`conversations`** (`app/models/conversation.rb`) — `status` enum (open/resolved/pending/snoozed),
`priority` enum, `display_id` (per-account), `assignee_id`, `assignee_agent_bot_id`, `ai_assignee`,
`team_id`, `waiting_since`, `first_reply_created_at`, `last_activity_at`, `additional_attributes`,
`custom_attributes`. Behaviour is split into concerns: `AssignmentHandler`, `AutoAssignmentHandler`,
`ActivityMessageHandler`, `SortHandler`, `PushDataHelper`, `Labelable`, `ConversationMuteHelpers`.

**`messages`** (`app/models/message.rb`) — `message_type` enum (incoming/outgoing/activity/template),
`content_type` enum (13 values incl. `input_csat`, `cards`, `form`, `voice_call`), `status` enum
(sent/delivered/read/failed), `source_id` (the external provider's message id — **the echo-loop guard**),
`content_attributes` jsonb store, `external_source_ids`, polymorphic `sender` (User / Contact / AgentBot /
Captain::Assistant). `after_create_commit :execute_after_create_commit_callbacks` is the hub of the
whole send pipeline.

### 4.3 Identity model (important for multi-channel)

`ContactInbox` (`app/models/contact_inbox.rb`) joins a `Contact` to an `Inbox` with a **`source_id`** —
the channel-native identifier (phone number, IG-scoped user id, page-scoped user id, widget token).
It also owns the `pubsub_token` used for end-user websocket auth. All inbound resolution goes
`source_id → ContactInbox → Contact + Conversation`.

---

## 5. Authentication and authorization

### 5.1 Authentication

- **Devise + devise_token_auth** (`config/initializers/devise.rb`, `devise_token_auth.rb`);
  overrides in `app/controllers/devise_overrides/`
- **Access tokens** — `AccessToken` model (`access_tokenable.rb` concern). API clients send
  `api_access_token`; `Api::BaseController#authenticate_by_access_token?` switches auth strategy on
  the header's presence. Both `User` and `AgentBot` are token-able.
- **OmniAuth** — Google (`config/initializers/omniauth.rb`); SAML lives in EE
  (`enterprise/config/initializers/omniauth_saml.rb`, `AccountSamlSettings`)
- **MFA** — `app/services/mfa/` (`authentication_service`, `management_service`, `token_service`);
  requires `ACTIVE_RECORD_ENCRYPTION_*` keys
- **Widget/end-user** — JWT-ish widget tokens (`app/services/widget/token_service.rb`) + optional
  HMAC identity validation (`HmacConcern`, `hmac_token` on `Channel::WebWidget`)
- **Platform API** — `PlatformApp` + `platform_app_permissibles`, a separate instance-level credential
- **Super admin** — separate Devise scope + `app/controllers/super_admin/` (Administrate)

### 5.2 Authorization

**Pundit**, with a non-standard user context. `ApplicationController#pundit_user` returns a hash:

```ruby
{ user: Current.user, account: Current.account, account_user: Current.account_user }
```

`app/policies/application_policy.rb` unpacks it into `@user`, `@account`, `@account_user`.
So **every policy has the tenant in hand** and can answer "in this account, can this user…".

Roles: `AccountUser#role` enum — `agent` (0) / `administrator` (1).
EE adds `CustomRole` (`enterprise/app/models/custom_role.rb`) and `custom_role_id` on `account_users`.

Representative policy — `app/policies/conversation_policy.rb`:

```ruby
def show?
  administrator? || agent_bot? || agent_can_view_conversation?
end
# agent_can_view_conversation? = inbox_access? || team_access?
```

and it ends with `ConversationPolicy.prepend_mod_with('ConversationPolicy')`, so EE can tighten it
for custom roles. Almost every policy has that hook.

Row-level scoping additionally happens in:
- `app/services/conversations/permission_filter_service.rb`
- `policy_scope(Current.account.inboxes)` in controllers
- `app/finders/conversation_finder.rb`

---

## 6. Multi-tenant / workspace architecture

Chatwoot is **single-database, row-level multi-tenant**. There is no schema-per-tenant, no
`default_scope` tenancy, and no Postgres RLS.

### 6.1 How isolation actually works

Three mechanisms, layered:

**(a) URL structure.** Every dashboard route and every account API route carries `:account_id`.
`config/routes.rb`: `namespace :accounts do; resources :accounts; scope 'accounts/:account_id' do … end`.

**(b) `EnsureCurrentAccountHelper`** (`app/controllers/concerns/ensure_current_account_helper.rb`) —
the chokepoint, run as a `before_action` in `Api::V1::Accounts::BaseController`:

```ruby
def ensure_current_account
  account = Account.find(params[:account_id])
  render_unauthorized('Account is suspended') and return unless account.active?
  if current_user
    account_accessible_for_user?(account)   # must have an AccountUser row
  elsif @resource.is_a?(AgentBot)
    account_accessible_for_bot?(account)
  else
    render_unauthorized(...)
  end
  account
end
```

It sets `Current.account` and `Current.account_user`.

**(c) `Current` (`lib/current.rb`)** — thread-local holder for `user`, `account`, `account_user`,
`executed_by`, `contact`, `inbox`. Controllers then query **through the association**:
`Current.account.inboxes`, `Current.account.conversations`, etc. Isolation is by association
traversal, not by a global scope.

### 6.2 Consequences you must design around

- A user can belong to **many accounts** (`AccountUser` is a join table with per-account role and
  per-account availability). "Workspace switching" is just changing the `account_id` in the URL.
- **Any query that starts from a model class rather than `Current.account` is a potential leak.**
  This is the number-one risk when adding endpoints.
- Per-account limits/usage live in `Account#usage_limits` (OSS returns `ChatwootApp.max_limit` i.e.
  effectively unlimited) and are overridden by
  `enterprise/app/models/enterprise/account/plan_usage_and_limits.rb`.
- Feature availability is **per account** via the bitset feature flags (§20).
- Account deletion is `AccountDeletionService` + `Internal::DeleteAccountsJob` (daily cron).
- Provisioning new accounts programmatically: `AccountBuilder` and the **Platform API**
  (`app/controllers/platform/api/v1/accounts_controller.rb`) — this is the intended SaaS control-plane door.

---

## 7. Conversation / inbox architecture

### 7.1 The inbox abstraction

An **Inbox** is the tenant-facing object; a **Channel::*** record is the transport. `Inbox belongs_to
:channel, polymorphic: true`. Creating an inbox creates a channel row and wraps it
(`Api::V1::Accounts::InboxesController#create_channel`). Deleting an inbox destroys the channel.

Everything downstream (conversations, messages, agents, automations, reports, webhooks) is written
against **Inbox**, not against the channel — which is exactly why adding a channel is cheap.

### 7.2 Conversation lifecycle

1. `ContactInboxWithContactBuilder` resolves/creates `Contact` + `ContactInbox` from a `source_id`.
2. `ConversationBuilder` reuses the last conversation when `inbox.lock_to_single_conversation?`,
   otherwise creates a new one.
3. Status machine: `open` ⇄ `pending` ⇄ `snoozed` → `resolved`. Reopening on a new incoming message is
   `Message#reopen_conversation`.
4. Assignment: `app/models/concerns/auto_assignment_handler.rb` →
   `AutoAssignment::AssignmentService` / `InboxRoundRobinService` (Redis-backed round robin), with
   `assignment_v2` behind a feature flag and `AssignmentPolicy` / `InboxAssignmentPolicy` records.
5. Activity messages (`message_type: activity`) are generated by the `*ActivityMessageHandler` concerns.
6. Auto-resolve: `Account#auto_resolve_after` setting + `AccountCaptainAutoResolve`.
7. SLA (`applied_slas`, `sla_policies`) and CSAT (`csat_survey_responses`, `CsatSurveyListener`).

### 7.3 Reply window

`app/services/conversations/message_window_service.rb` + `Conversation#can_reply?` enforce provider
messaging windows (e.g. WhatsApp 24h). `Whatsapp::SendOnWhatsappService` fails the message with
`errors.whatsapp.message_outside_messaging_window` when the window is closed.

---

## 8. Channel architecture

### 8.1 The contract

Every channel model lives in `app/models/channel/` and includes `Channelable`
(`app/models/concerns/channelable.rb`):

```ruby
module Channelable
  included do
    validates :account_id, presence: true
    belongs_to :account
    has_one :inbox, as: :channel, dependent: :destroy_async, touch: true
    after_update :create_audit_log_entry
  end
end
```

Each channel implements:
- `#name` — human label shown in the UI (`Inbox#inbox_type` delegates to it)
- `EDITABLE_ATTRS` — the strong-params allowlist used by `InboxesController`
- optionally `Reauthorizable` (`app/models/concerns/reauthorizable.rb`) — auth-error counting,
  `prompt_reauthorization!`, `reauthorized!`

### 8.2 The channels

| Model | Table | Inbound path | Outbound service |
|---|---|---|---|
| `Channel::WebWidget` | `channel_web_widgets` | `public/api/v1/inboxes/...` + widget API | `Messages::SendEmailNotificationService` |
| `Channel::Api` | `channel_api` | `/api/v1/accounts/:id/conversations` | `Messages::SendEmailNotificationService` |
| `Channel::Email` | `channel_email` | ActionMailbox + IMAP (`Imap::FetchEmailService`) | `Email::SendOnEmailService` |
| `Channel::Whatsapp` | `channel_whatsapp` | `POST /webhooks/whatsapp/:phone_number` | `Whatsapp::SendOnWhatsappService` |
| `Channel::FacebookPage` | `channel_facebook_pages` | `mount Facebook::Messenger::Server, at: 'bot'` | `Facebook::SendOnFacebookService` |
| `Channel::Instagram` | `channel_instagram` | `POST /webhooks/instagram` | `Instagram::SendOnInstagramService` |
| `Channel::TwilioSms` | `channel_twilio_sms` | `POST /twilio/callback` | `Twilio::SendOnTwilioService` |
| `Channel::Sms` | `channel_sms` | `POST /webhooks/sms/:phone_number` | `Sms::SendOnSmsService` |
| `Channel::Telegram` | `channel_telegram` | `POST /webhooks/telegram/:bot_token` | `Telegram::SendOnTelegramService` |
| `Channel::Line` | `channel_line` | `POST /webhooks/line/:line_channel_id` | `Line::SendOnLineService` |
| `Channel::Tiktok` | `channel_tiktok` | `POST /webhooks/tiktok` | `Tiktok::SendOnTiktokService` |
| `Channel::TwitterProfile` | `channel_twitter_profiles` | `POST /webhooks/twitter` | `Twitter::SendOnTwitterService` |

### 8.3 The dispatch table

`app/jobs/send_reply_job.rb` holds a literal `CHANNEL_SERVICES` hash from channel class name to send
service, with a special case: `Channel::FacebookPage` routes to `Instagram::Messenger::SendOnInstagramService`
when `conversation.additional_attributes['type'] == 'instagram_direct_message'`, else to Facebook.

**Adding a channel = a model + a webhook controller + a job + an incoming service + a send service +
an entry in `CHANNEL_SERVICES` + an entry in `allowed_channel_types`.**

### 8.4 Inbox creation allowlist

`Api::V1::Accounts::InboxesController#allowed_channel_types` currently returns
`%w[web_widget api email line telegram whatsapp sms]`. Facebook, Instagram, TikTok and Twilio have
**dedicated OAuth/setup controllers** instead (`callbacks_controller.rb`,
`accounts/instagram/authorizations_controller.rb`, `accounts/whatsapp/authorizations_controller.rb`,
`accounts/tiktok/authorizations_controller.rb`, `accounts/channels/twilio_channels_controller.rb`).

---

## 9. WhatsApp integration

The largest and most actively developed channel — ~45 files under `app/services/whatsapp/`.

### 9.1 Providers

`Channel::Whatsapp#provider` ∈ `%w[default whatsapp_cloud]`:
- `whatsapp_cloud` → `Whatsapp::Providers::WhatsappCloudService` (Meta Cloud API) — the modern path
- `default` → `Whatsapp::Providers::Whatsapp360DialogService` (360dialog) — legacy
- Plus `Channel::TwilioSms` with `medium: 'whatsapp'` — a **completely separate** WhatsApp path
  (`Inbox#twilio_whatsapp?`, `Twilio::SendOnTwilioService`)

`provider_service` is the polymorphic seam; the channel delegates `send_message`, `send_template`,
`sync_templates`, `media_url`, `api_headers` to it.

### 9.2 Onboarding paths

1. **Embedded signup** (Meta's popup OAuth) — `Whatsapp::EmbeddedSignupService`,
   `TokenExchangeService`, `ChannelCreationService`, `PhoneInfoService`; marked by
   `provider_config['source'] == 'embedded_signup'`
2. **Manual setup** — `Whatsapp::ManualSetupService` + `ManualSetupValidationService`
   (`source: 'manual_setup_v2'`), API-key based; `manual_setup_controller.rb` exposes
   `webhook_status` / `setup_webhook`
3. Webhook registration: `Whatsapp::WebhookSetupService` / `WebhookTeardownService`.
   `should_auto_setup_webhooks?` skips auto-setup for the two explicit flows so their API responses
   reflect real results.

### 9.3 Inbound

`POST /webhooks/whatsapp/:phone_number` → `Webhooks::WhatsappController`:
- `MetaTokenVerifyConcern#verify_meta_signature!` — HMAC-SHA256 over the raw body against a list of
  candidate app secrets (channel-level, then global `WHATSAPP_APP_SECRET`)
- rejects inactive numbers via `GlobalConfig.get_value('INACTIVE_WHATSAPP_NUMBERS')`
- short-circuits `tracking_events` payloads
- enqueues `Webhooks::WhatsappEventsJob`

`Webhooks::WhatsappEventsJob` (extends `MutexApplicationJob`):
- resolves the channel from the payload metadata (`Whatsapp::WebhookChannelFinderService` on
  `display_phone_number` / `phone_number_id`) rather than trusting the URL
- takes a **Redis mutex per (inbox, sender)** with a 30s TTL so concurrent album-upload webhooks
  serialize into one conversation; retry budget (19 × 2s) deliberately exceeds the TTL
- detects `smb_message_echoes` (WhatsApp coexistence: messages sent from the WhatsApp Business app)
  and processes them as outgoing echoes
- routes to `Whatsapp::IncomingMessageWhatsappCloudService` or `Whatsapp::IncomingMessageService`

`Whatsapp::IncomingMessageBaseService#perform`:
1. `process_statuses` for delivery receipts → `Messages::StatusUpdateService`
2. `process_identity_change_messages` (BSUID rotation — `Whatsapp::UserIdRotationService`)
3. `process_messages`: dedupe via `find_message_by_source_id` + an atomic Redis `SET NX`
   (`Whatsapp::MessageDedupLock`), `set_contact`, block check, then in a transaction
   `set_conversation` + `create_messages`

Conversation reuse is scoped to the **contact_inbox**, not the contact, when identifiers are
addressable — a deliberate design note in the source about coexistence and merged contacts.

### 9.4 Outbound

`Whatsapp::SendOnWhatsappService#perform_reply` branches:
- template params present → `Whatsapp::TemplateProcessorService` → `channel.send_template`
- contact-info request → `ContactInfoRequestEligibilityService` → `send_contact_info_request`
- inside the reply window → `channel.send_message`
- otherwise → mark the message `failed` with `errors.whatsapp.message_outside_messaging_window`

Supporting cast: `TemplateContentRendererService`, `TemplateParameterConverterService`,
`PopulateTemplateParametersService`, `LiquidTemplateProcessorService`, `AuthenticationTemplateGuard`,
`MediaUploadService`, `PhoneNumberNormalizationService` (+ country-specific normalizers for
AR/BR/MX), `HealthService`, `ReauthorizationService`, `CsatTemplateService`.

### 9.5 Voice

`Channel::Whatsapp#voice_enabled?` gates Meta's Calling API behind `whatsapp_cloud` +
`provider_config['calling_enabled']` + the `channel_voice` account feature. Call plumbing is EE
(`enterprise/app/jobs/voice/`, `enterprise/app/models/call.rb`).

---

## 10. Instagram integration

**Two distinct paths exist** — this is the most common source of confusion.

### 10.1 Path A — `Channel::Instagram` (Instagram Login, current)

`app/models/channel/instagram.rb`, table `channel_instagram`, key is `instagram_id`,
`access_token` is encrypted. On create it `POST`s to
`graph.instagram.com/<version>/<instagram_id>/subscribed_apps` with
`subscribed_fields: %w[messages message_reactions messaging_seen]`; on destroy it unsubscribes.
Token refresh: `Instagram::RefreshOauthTokenService` (called on every `access_token` read).

OAuth: `GET /instagram/callback` → `app/controllers/instagram/callbacks_controller.rb` +
`Api::V1::Accounts::Instagram::AuthorizationsController` (+ `InstagramConcern`).

Outbound: `Instagram::SendOnInstagramService < Instagram::BaseSendService` — posts to
`graph.instagram.com/<version>/<ig_id>/messages`; optionally adds the `HUMAN_AGENT` message tag when
`ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT` global config is on.

### 10.2 Path B — `Channel::FacebookPage` with `instagram_id` set (legacy, via Facebook page)

`Inbox#instagram?` returns true for `(facebook? || instagram_direct?) && channel.instagram_id.present?`.
Messages are built by `app/builders/messages/instagram/messenger/` and sent by
`Instagram::Messenger::SendOnInstagramService`, selected inside `SendReplyJob#send_on_facebook_page`
via `conversation.additional_attributes['type'] == 'instagram_direct_message'`.

### 10.3 Inbound (shared)

`POST /webhooks/instagram` → `Webhooks::InstagramController#events`:
- verifies `X-Hub-Signature-256` against app secrets gathered from **both** `Channel::Instagram` and
  `Channel::FacebookPage` rows found in the payload, plus global `INSTAGRAM_APP_SECRET` / `FB_APP_SECRET`
- `GET /webhooks/instagram` verifies `hub.verify_token` against `IG_VERIFY_TOKEN` **or**
  `INSTAGRAM_VERIFY_TOKEN` (one per path)
- **echo events are delayed 2 seconds** (`set(wait: 2.seconds)`) to avoid racing the send API and
  double-posting the agent's own message

`Webhooks::InstagramEventsJob` takes a short Redis mutex per (sender, ig account) with a 3s TTL,
deterministic backoff, and — notably — falls back to `process_without_lock` rather than dropping the
webhook when retries are exhausted. Supported events: `message`, `read`, `postback`.

Services: `Instagram::WebhooksBaseService`, `MessageText`/`BaseMessageText`, `UserDetailsService`,
`ReadStatusService`, `TestEventService`.

---

## 11. Facebook / Messenger integration

Unlike every other channel, Facebook does **not** use a Chatwoot controller. The `facebook-messenger`
gem mounts its own Rack server:

```ruby
# config/routes.rb:671
mount Facebook::Messenger::Server, at: 'bot'
```

`config/initializers/facebook_messenger.rb` defines `ChatwootFbProvider` (a gem configuration provider):
- `access_token_for(page_id)` → `Channel::FacebookPage.where(page_id:).last.page_access_token`
- `app_secret_for(page_id)` → per-channel secret (checking `app_secret`, `app_secret_key`,
  `client_secret`, `api_secret` in `provider_config`) falling back to global `FB_APP_SECRET`
- `valid_verify_token?` → `FB_VERIFY_TOKEN`

and registers bot handlers:

| Event | Handler |
|---|---|
| `:message` | `Webhooks::FacebookEventsJob.perform_later` |
| `:message_echo` | same, **delayed 2s** (same race guard as Instagram) |
| `:postback` | `Webhooks::FacebookEventsJob` |
| `:delivery`, `:read` | `Webhooks::FacebookDeliveryJob` |

`Webhooks::FacebookEventsJob` → `Integrations::Facebook::MessageParser` → Redis mutex per
(sender, recipient) → `Integrations::Facebook::MessageCreator` (in `lib/integrations/facebook/`) →
`app/builders/messages/facebook/message_builder.rb`.

Page connection: `Api::V1::Accounts::CallbacksController` (`register_facebook_page`, `facebook_pages`)
+ `Facebook::PageDetailsService`.

Outbound: `Facebook::SendOnFacebookService` → `Facebook::Messenger::Bot.deliver(params, page_id:)`;
errors go through `Messages::StatusUpdateService(message, 'failed', …)` and, on auth errors,
`prompt_reauthorization!`.

---

## 12. Webhook architecture

Three separate concepts share the word "webhook":

### 12.1 Inbound (providers → Chatwoot)

`app/controllers/webhooks/*.rb`, all `ActionController::API`, all doing the same three things:
verify signature/token → enqueue a job → `head :ok`. Never process inline.
Shared verification: `app/controllers/concerns/meta_token_verify_concern.rb` (Meta),
`HmacConcern`, `Shopify`/`Twilio`/`Line`/`Telegram` each with their own token scheme.

### 12.2 Outbound (Chatwoot → customer systems)

- Model: `app/models/webhook.rb` — `webhook_type` enum `account_type`/`inbox_type`, a `subscriptions`
  array validated against `ALLOWED_WEBHOOK_EVENTS`:
  `conversation_status_changed, conversation_updated, conversation_created, contact_created,
   contact_updated, message_created, message_updated, webwidget_triggered, inbox_created,
   inbox_updated, conversation_typing_on, conversation_typing_off`
- Signing: `app/models/concerns/webhook_secretable.rb`
- Listener: `app/listeners/webhook_listener.rb` — builds `*.webhook_data` payloads and calls
  `deliver_webhook_payloads(payload, inbox)`
- Delivery: `WebhookJob` (queue `medium`) → `lib/webhooks/trigger.rb`
- Also: `InstallationWebhookListener` (instance-wide webhook) and `AgentBotListener`
  (per-bot outbound webhooks via `Integrations::BotProcessorService`)

### 12.3 Integrations / hooks

`Integrations::App` (`config/integration/apps.yml`) + `Integrations::Hook` (account- or inbox-scoped,
with `settings_json_schema` validation). `HookListener` dispatches events to hook processors in
`lib/integrations/` (Slack, Dialogflow, OpenAI, Google Translate, Linear, Dyte, Cloudflare, Captain).

**Adding an integration = a YAML entry + a processor service. No core changes.**

---

## 13. Message sending / receiving flow

### 13.1 Inbound (customer → agent UI)

```
Provider HTTP POST
  → Webhooks::XController          verify signature, enqueue, head :ok
  → Webhooks::XEventsJob           Redis mutex per (inbox, sender); dedupe by source_id
  → X::IncomingMessageService      resolve contact/contact_inbox by source_id
       ContactInboxWithContactBuilder → Contact + ContactInbox
       ConversationBuilder            → reuse or create Conversation
       Messages::XMessageBuilder      → Message(message_type: :incoming, source_id: <provider id>)
  → Message#after_create_commit → execute_after_create_commit_callbacks
       reopen_conversation
       mark_pending_conversation_as_open_for_human_response
       set_conversation_activity
       dispatch_create_events   → MESSAGE_CREATED
       send_reply               → (no-op for incoming)
       execute_message_template_hooks
       update_contact_activity
  → Dispatcher
       sync : ActionCableListener → ActionCableBroadcastJob → websocket
              AgentBotListener    → bot webhook
       async: EventDispatcherJob  → Automation, Campaign, CSAT, Hook, Notification,
                                    Participation, UnreadCounts, ReportingEvent, Webhook
```

### 13.2 Outbound (agent → customer)

```
Agent clicks send in dashboard
  → POST /api/v1/accounts/:id/conversations/:cid/messages
  → Api::V1::Accounts::Conversations::MessagesController#create
  → Messages::MessageBuilder.new(user, conversation, params).perform
       builds message, attachments, email cc/bcc, quoted content → save!
  → Message#after_create_commit
       dispatch_create_events  → MESSAGE_CREATED → ActionCable echo to all agents
       send_reply              → SendReplyJob.perform_later (slight delay for attachments)
  → SendReplyJob               CHANNEL_SERVICES[channel_class] lookup
  → X::SendOnXService < Base::SendOnChannelService
       validate_target_channel
       return unless message.outgoing? || message.template?
       return if message.private? || message.source_id.present? || content_type == 'voice_call'
       perform_reply → provider API call
       message.update!(source_id: <provider message id>)
  → provider delivery receipt webhook → Messages::StatusUpdateService → status: delivered/read
```

**The echo-loop guard.** `Base::SendOnChannelService#invalid_message?` skips any message that already
has a `source_id`, because a message created *from* a provider webhook already carries one. This is
why inbound builders must always set `source_id` and outbound services must set it *after* sending.

### 13.3 Message retry

`MessagesController#retry` takes a row lock, requires `failed?`, resets status via
`Messages::StatusUpdateService`, clears `source_id` (except for API/web-widget inboxes), then
re-enqueues `SendReplyJob`.

---

## 14. Realtime architecture

**ActionCable over Redis**, with one channel and token-based addressing.

### 14.1 Server

- `app/channels/room_channel.rb` — the only channel. On subscribe it resolves the subscriber from a
  **`pubsub_token`**: a `User` (when `params[:user_id]` is present) or a `Contact` via
  `ContactInbox.find_by!(pubsub_token:)`. It then `stream_from pubsub_token` and, for users,
  additionally `stream_from "account_#{account.id}"`.
- Presence: `lib/online_status_tracker.rb` (Redis sorted sets), refreshed by `update_presence`
  every 20s from the client.
- Broadcast path: `ActionCableListener#broadcast(account, tokens, event_name, data)` →
  `ActionCableBroadcastJob.perform_later(tokens.uniq, event_name, payload)`.
  Payload always gets `account_id`, and `performer` (`Current.user.push_event_data`) so the client
  knows who acted.
- Audience selection is explicit per event, e.g. `message_created` targets
  `user_tokens(account, conversation.inbox.members) + contact_tokens(conversation.contact_inbox, message)`.

**Isolation note:** websocket delivery is by *token list*, not by channel name — the server decides
the recipients server-side. That is a sound design and should not be replaced with a broadcast-to-all.

### 14.2 Client

- `app/javascript/shared/helpers/BaseActionCableConnector.js` — consumer creation, reconnect timer,
  20s presence heartbeat
- `app/javascript/dashboard/helper/actionCable.js` — the event → Vuex/Pinia router. Handles
  `message.created`, `message.updated`, `conversation.created`, `conversation.status_changed`,
  `conversation.typing_on/off`, `presence.update`, `notification.*`, `contact.*`, `assignee.changed`,
  `user:logout`, `page:reload`, call events, unread-count events.
- `app/javascript/widget/helpers/actionCable.js` — the widget's counterpart

---

## 15. Background jobs / Sidekiq

- Config: `config/sidekiq.yml`, concurrency from `SIDEKIQ_CONCURRENCY` (default 10).
- **Strictly ordered queues** (no weights — lower queues only run when higher ones are empty):
  `critical, high, medium, default, mailers, action_mailbox_routing, low, scheduled_jobs, deferred,
   purgable, housekeeping, async_database_migration, bulk_reindex_low, active_storage_*`
- Notable placements: `SendReplyJob` → `high`; `WebhookJob` → `medium`;
  `Webhooks::WhatsappEventsJob` → `low`; `Webhooks::{Facebook,Instagram}EventsJob` → `default`.
- Base classes: `ApplicationJob`, and `MutexApplicationJob` (`app/jobs/mutex_application_job.rb`) which
  provides `with_lock(key, ttl)` over Redis and a `LockAcquisitionError` for `retry_on`.
- Cron: `sidekiq-cron` via `config/schedule.yml` — IMAP fetch every minute,
  `TriggerScheduledItemsJob` every 5 minutes, daily housekeeping (stale contacts/contact-inboxes/redis
  keys, account deletion), `Internal::TriggerDailyScheduledItemsJob` / `TriggerHourlyScheduledItemsJob`.
- `EventDispatcherJob` is the async half of the event bus — everything listener-driven lands here.

---

## 16. API architecture

`config/routes.rb` defines five distinct API surfaces:

| Surface | Prefix | Auth | Purpose |
|---|---|---|---|
| **Application API v1** | `/api/v1/accounts/:account_id/...` | user session or `api_access_token` | The dashboard's own API; also the documented public API |
| **Application API v2** | `/api/v2/accounts/:account_id/...` | same | Reports (`V2::ReportBuilder`) |
| **Enterprise API** | `/enterprise/api/v1/...` | same | EE-only resources (`ApiClient` adds the prefix when `options.enterprise`) |
| **Platform API** | `/platform/api/v1/...` | `PlatformApp` access token | Instance-level provisioning: accounts, users, account_users, agent_bots. **The SaaS control plane.** |
| **Public API** | `/public/api/v1/...` | inbox identifier / none | Widget conversations + help-center portals; used by non-authenticated clients |

Plus: `/webhooks/*` (providers), `/bot` (Facebook Messenger gem), `/super_admin/*` (Administrate),
`/survey/*` (CSAT), `/widget` (widget shell), `/app/*` (SPA catch-all → `dashboard#index`).

- Responses are **Jbuilder views** under `app/views/api/...` — not serializers. Changing a response
  shape means editing a `.json.jbuilder` file.
- API docs: `swagger/` (OpenAPI 3.1, split into `paths/`, `definitions/`, `parameters/`,
  assembled into `swagger/swagger.json`).
- Rate limiting: `config/initializers/rack_attack.rb`.

---

## 17. Existing UI component system

**Two generations coexist.** This matters a great deal for where you put new code.

| | `dashboard/components/` | `dashboard/components-next/` |
|---|---|---|
| Count | 164 `.vue` | 494 `.vue` |
| Status | **Legacy, being deprecated** | **Current — put new UI here** |
| Style | Options API remnants, some custom SCSS | `<script setup>`, Tailwind-only |

`components-next/` is organised by domain and by primitive:

- Domain: `Conversation/`, `Contacts/`, `Campaigns/`, `Inbox/`, `HelpCenter/`, `Settings/`,
  `Companies/`, `Calls/`, `captain/`, `copilot/`, `NewConversation/`, `ConversationWorkflow/`
- Primitives: `button/`, `buttonGroup/`, `checkbox/`, `combobox/`, `dialog/`, `dropdown-menu/`,
  `avatar/`, `banner/`, `breadcrumb/`, `filter/`, `colorpicker/`, `emoji-icon-picker/`, `accordion/`
- Layout: `CardLayout.vue`, `EmptyStateLayout.vue`, `SidebarActionsHeader.vue`,
  `TeleportWithDirection.vue`

Stories: **Histoire** (`histoire.config.ts`, `pnpm story:dev`) with `*.story.vue` files
(e.g. `SidebarActionsHeader.story.vue`).

Message bubbles specifically: `AGENTS.md` states *"Use `components-next/` for message bubbles (the
rest is being deprecated)"* — `components-next/message/`.

State: Vuex is still primary (`store/modules/`), Pinia is the newer target (`stores/`). New stores
should be Pinia; existing Vuex modules should not be rewritten wholesale.

---

## 18. Existing design system

There is **no separate component library package** — the design system is Tailwind configuration plus
the `components-next/` primitives.

- `tailwind.config.js` — `darkMode: 'class'`, content globs covering every JS app; extends
  `fontFamily` (Inter / InterDisplay), custom `fontWeight` values (420/440/460/520/620), a `bubble`
  typography preset for message rendering
- `theme/colors.js` — colour tokens, built on `@radix-ui/colors` (`slateDark` etc.), exposed as CSS
  variables like `rgb(var(--slate-12))`
- `theme/icons.js` + `@egoist/tailwindcss-icons` — icon collections from `@iconify-json/*`
  (`lucide`, `ph`, `ri`, `fluent`, `material-symbols`, `teenyicons`, `logos`)
- `app/javascript/design-system/` — currently only brand images (`logo.png`, `logo-dark.png`,
  `logo-thumbnail.svg`) + `histoire.scss`
- `public/brand-assets/` — runtime-swappable logo/favicon referenced by `installation_config.yml`

**Rules from `AGENTS.md` that the codebase actually enforces:** Tailwind only, no scoped CSS, no
inline styles, use typography utilities rather than hand-rolled font styles, use logical properties
(`ms`/`me`/`start`/`end`), `rem` for arbitrary dimensions, extract repeated values into named constants.

---

## 19. Enterprise directory and licensing boundaries

### 19.1 The licensing split

- Root `LICENSE` — **MIT** (the OSS app)
- `enterprise/LICENSE` — **Chatwoot Enterprise License**. Verbatim: production use requires a valid
  Chatwoot Enterprise subscription for the correct number of seats; you may modify for development
  and testing without a subscription, but *"Chatwoot and/or its licensors retain all right, title and
  interest in and to all such modifications"* and it is *"forbidden to copy, merge, publish,
  distribute, sublicense, and/or sell the Software."*

> **This is the single most important constraint for a commercial branded SaaS.**
> Everything under `enterprise/` is *not* MIT. Building a product on top of it — or on features it
> gates (SLA, audit logs, custom roles, Captain AI, SAML, companies, voice/calls) — requires a
> Chatwoot Enterprise subscription. Get legal sign-off before depending on any of it.
> `DISABLE_ENTERPRISE=true` (see `ChatwootApp.enterprise?`) is the supported way to run OSS-only.

### 19.2 How the overlay works

`config/initializers/01_inject_enterprise_edition_module.rb` (adapted from GitLab) adds
`prepend_mod_with` / `include_mod_with` / `extend_mod_with` to every `Module`. `ChatwootApp.extensions`
returns `%w[enterprise]` when `enterprise/` exists and `DISABLE_ENTERPRISE` is unset — and
`%w[enterprise custom]` when a **`custom/`** directory exists.

Usage pattern at the bottom of OSS files:

```ruby
Inbox.prepend_mod_with('Inbox')                 # → Enterprise::Inbox (and Custom::Inbox)
Inbox.include_mod_with('Concerns::Inbox')       # → Enterprise::Concerns::Inbox
Account.prepend_mod_with('Account::PlanUsageAndLimits')
ConversationPolicy.prepend_mod_with('ConversationPolicy')
SyncDispatcher.prepend_mod_with('SyncDispatcher')
```

So EE customises OSS behaviour by defining `Enterprise::<Constant>` — no OSS file edits.

### 19.3 What lives in `enterprise/`

- **Captain** (AI): assistants, documents, scenarios, custom tools, copilot, FAQ suggestions —
  `enterprise/app/models/captain/`, `enterprise/lib/captain/` (Liquid prompt templates)
- **SLA**: `sla_policies`, `applied_slas`, `sla_events`
- **Audit logs**: `Enterprise::Audit::*` concerns on Account, Conversation, Inbox, User, …
- **Custom roles**: `CustomRole` + policy overrides
- **SAML SSO**: `AccountSamlSettings`, `enterprise/config/initializers/omniauth_saml.rb`
- **Companies**: `Company` model + CRM sync
- **Voice/Calls**: `Call`, `enterprise/app/jobs/voice/`
- **Billing**: `enterprise/app/jobs/enterprise/billing/`, Stripe
- **Agent capacity policies**, **conversation outcomes**, **campaign recipients**
- Feature gating lists: `enterprise/config/premium_features.yml`
  (`disable_branding, audit_logs, sla, custom_roles, captain_integration, captain_integration_v2,
   captain_document_auto_sync, csat_review_notes, conversation_required_attributes`)
  and `enterprise/config/premium_installation_config.yml`

### 19.4 Deployment tier detection (`lib/chatwoot_app.rb`)

```ruby
enterprise?            # enterprise/ exists && !DISABLE_ENTERPRISE
chatwoot_cloud?        # enterprise? && DEPLOYMENT_ENV == 'cloud'
self_hosted_enterprise? # enterprise? && !cloud && INSTALLATION_PRICING_PLAN == 'enterprise'
self_hosted_paid?      # enterprise? && !cloud && ChatwootHub.pricing_plan in [premium, enterprise]
custom?                # custom/ directory exists   ← the un-documented third overlay
extensions             # %w[enterprise custom] | %w[enterprise] | []
```

---

## 20. Configuration / environment setup

Chatwoot has **three configuration tiers**, and knowing which to use is essential for white-labelling.

### Tier 1 — Environment variables (`.env.example`, ~13 KB)

Infra-level and boot-time: `SECRET_KEY_BASE`, `FRONTEND_URL`, `HELPCENTER_URL`, `POSTGRES_*`,
`REDIS_URL`/`REDIS_SENTINELS`, `ACTIVE_RECORD_ENCRYPTION_*` (required for MFA), `RAILS_ENV`,
`FORCE_SSL`, `ENABLE_ACCOUNT_SIGNUP` (`true` / `false` / `api_only`), `SIDEKIQ_CONCURRENCY`,
`DEFAULT_LOCALE`, `ASSET_CDN_HOST`, `OPENSEARCH_URL`, storage (`ACTIVE_STORAGE_SERVICE`, S3/GCS/Azure),
mail (`MAILER_SENDER_EMAIL`, `SMTP_*`, `MAILER_INBOUND_EMAIL_DOMAIN`), and `DISABLE_ENTERPRISE`.

### Tier 2 — Installation configs (`config/installation_config.yml` → `installation_configs` table)

Runtime, DB-backed, editable at **Super Admin → Settings**. Read through
`GlobalConfig.get_value(key)` / `GlobalConfigService.load(key, default)` with a **1-day Redis cache**
(`lib/global_config.rb`). `GlobalConfigService.load` also falls back to an ENV var of the same name
and then persists it as an unlocked `InstallationConfig` — the migration path from Tier 1 to Tier 2.

The **branding block is the first section of the file** and is exactly what a white-label needs:

```yaml
INSTALLATION_NAME  # used in the dashboard title, page titles, UI copy
LOGO_THUMBNAIL     # favicon, 512x512
LOGO               # dashboard / login
LOGO_DARK          # dark mode
BRAND_URL          # "Powered by" link in emails
WIDGET_BRAND_URL   # "Powered by" link in the widget
BRAND_NAME         # emails + widget
TERMS_URL / PRIVACY_URL
```

Also here: channel credentials (`FB_APP_ID`, `FB_APP_SECRET`, `FB_VERIFY_TOKEN`, `IG_VERIFY_TOKEN`,
`INSTAGRAM_APP_SECRET`, `INSTAGRAM_VERIFY_TOKEN`, `WHATSAPP_APP_SECRET`,
`INACTIVE_WHATSAPP_NUMBERS`, `INSTAGRAM_API_VERSION`), `DEPLOYMENT_ENV`,
`INSTALLATION_PRICING_PLAN`, `ACCOUNT_LEVEL_FEATURE_DEFAULTS`, `OTEL_PROVIDER`/`LANGFUSE_SECRET_KEY`.

`locked: true` (the default when unspecified) hides a config from the Super Admin UI.

### Tier 3 — Per-account feature flags (`config/features.yml` → bitset columns)

142 features, stored as bits on `accounts.feature_flags` and `accounts.feature_flags_ext_1`
(FlagShihTzu, via `app/models/concerns/featurable.rb`). API: `account.feature_enabled?('name')`,
`enable_features!`, `disable_features!`. Frontend mirror: `dashboard/featureFlags.js`.

> ⚠️ **Hard constraint documented in the file itself:** `feature_flags` is **full (63/63)**. New flags
> **must** set `column: feature_flags_ext_1` and be **appended at the end**. Never reorder, remove, or
> move an existing entry — bit positions are persisted. `Featurable` raises `ArgumentError` if you
> exceed 63 per column or use an unknown column.

Defaults for new accounts come from the `ACCOUNT_LEVEL_FEATURE_DEFAULTS` installation config, not
from the YAML's `enabled:` alone.

### Other config

`config/integration/apps.yml` (integration catalogue), `config/llm.yml` + `config/llm_models.json`,
`config/languages/`, `config/schedule.yml`, `config/sidekiq.yml`, `config/features.yml`.

---

## 21. Key narratives

### 21.1 How a message enters the system

1. The provider POSTs to a route in `config/routes.rb` (`/webhooks/whatsapp/:phone_number`,
   `/webhooks/instagram`, `/bot`, `/twilio/callback`, …).
2. A thin `ActionController::API` controller **verifies the signature** (HMAC-SHA256 over the raw body
   for Meta, via `MetaTokenVerifyConcern`) and **immediately enqueues** a job. It never processes inline.
3. The job (`Webhooks::*EventsJob`, a `MutexApplicationJob`) takes a **Redis mutex keyed on
   (inbox, sender)** so concurrent webhooks for the same conversation serialize, then resolves the
   channel — from the *payload*, not the URL, for WhatsApp.
4. An incoming service (`Whatsapp::IncomingMessageBaseService`, `Integrations::Facebook::MessageCreator`,
   `Instagram::WebhooksBaseService`, …) **dedupes by `source_id`** (DB lookup + an atomic Redis `SET NX`).
5. `ContactInboxWithContactBuilder` resolves `Contact` + `ContactInbox` from the channel-native
   `source_id`; `ConversationBuilder` reuses or creates the `Conversation`; a channel-specific
   message builder creates the `Message` with `message_type: :incoming` and `source_id` set.
6. `Message#after_create_commit` reopens the conversation if needed, sets activity timestamps, and
   dispatches `MESSAGE_CREATED`.

### 21.2 How a message reaches the UI

1. `Dispatcher#dispatch` runs `SyncDispatcher` **in-request**.
2. `ActionCableListener#message_created` computes the recipient token list —
   `user_tokens(account, conversation.inbox.members) + contact_tokens(conversation.contact_inbox, message)` —
   and calls `broadcast`, which merges `account_id` and `performer` into the payload.
3. `ActionCableBroadcastJob` (Sidekiq) publishes to each `pubsub_token` stream over Redis.
4. `RoomChannel` is streaming each of those tokens for connected clients.
5. In the browser, `BaseActionCableConnector.onReceived` → `dashboard/helper/actionCable.js`
   `events['message.created']` → Vuex mutation → the conversation view re-renders.
6. In parallel, `AsyncDispatcher` → `EventDispatcherJob` runs notifications, automations,
   unread counts, reporting events and outbound webhooks.

### 21.3 How an agent sends a message

1. `POST /api/v1/accounts/:account_id/conversations/:conversation_id/messages`
2. `Api::V1::Accounts::BaseController` resolves and authorizes `Current.account`.
3. `MessagesController#create` → `Messages::MessageBuilder.new(user, conversation, params).perform` —
   builds the message, attaches files, processes cc/bcc for email inboxes, handles quoted content,
   `save!`.
4. `Message#after_create_commit`:
   - `dispatch_create_events` → `MESSAGE_CREATED` → ActionCable → **the sending agent and every other
     agent see the bubble immediately**, before the provider is contacted
   - `send_reply` → `SendReplyJob.perform_later(message.id)` (with a short delay so ActiveStorage
     attachments are committed)
5. `SendReplyJob` looks the channel class up in `CHANNEL_SERVICES` and instantiates the send service.
6. `Base::SendOnChannelService#perform` validates the channel, requires `outgoing?`/`template?`,
   and **bails if `source_id` is present** (that means the message came from the channel).
7. `perform_reply` calls the provider; the returned provider message id is written back to
   `message.source_id`.
8. Delivery/read receipts arrive on the inbound webhook and flow through
   `Messages::StatusUpdateService` → `message.status` → `MESSAGE_UPDATED` → ActionCable.
9. Failures set `status: :failed` + `external_error`; the agent can call `POST .../messages/:id/retry`.

### 21.4 How channels are connected

Two shapes:

**Credential-based** (web widget, API, email, SMS, Telegram, Line, WhatsApp-manual):
`POST /api/v1/accounts/:id/inboxes` with `channel: { type: 'whatsapp', ... }`.
`InboxesController#create_channel` checks `allowed_channel_types`, calls
`account_channels_method.create!(...)` with the channel's `EDITABLE_ATTRS`, and wraps it in an inbox
in one transaction.

**OAuth-based** (Facebook, Instagram, TikTok, WhatsApp embedded signup):
a redirect to the provider → a callback controller (`/instagram/callback`, `/tiktok/callback`,
`api/v1/accounts/callbacks#register_facebook_page`) → a channel-creation service
(`Whatsapp::ChannelCreationService`, `Facebook::PageDetailsService`) → the inbox.

Webhook registration then happens either automatically (`Channel::Whatsapp#should_auto_setup_webhooks?`,
`Channel::Instagram#subscribe` on `after_create_commit`) or explicitly via a setup endpoint so the
API response can surface real errors. Teardown mirrors it on `before_destroy`.

### 21.5 How organizations / workspaces are isolated

Recap of §6, as a checklist:
- Every account-scoped route carries `:account_id` in the path.
- `Api::V1::Accounts::BaseController` runs `EnsureCurrentAccountHelper#current_account`, which checks
  the account is `active?` and that an `AccountUser` row exists for `current_user` (or that an
  `AgentBot` is authorized), then sets `Current.account` / `Current.account_user`.
- Controllers query **through** `Current.account` (`Current.account.inboxes.find(...)`), so the
  `account_id` filter is in the SQL by construction.
- Pundit policies receive `{ user, account, account_user }` and add role/inbox/team checks on top.
- Realtime fan-out picks explicit recipient token lists server-side; the widget authenticates with a
  `ContactInbox#pubsub_token`.
- There is **no** database-level tenancy (no RLS, no `default_scope`). Discipline at the controller
  boundary is the whole mechanism.

---

## 22. Reuse / customize / avoid

### 22.1 Reuse as-is (do not re-implement)

| Area | Why |
|---|---|
| Event dispatcher + listeners (`app/dispatchers/`, `app/listeners/`) | Clean fan-out, already EE-extensible. Hook new behaviour here. |
| `Base::SendOnChannelService` contract | Every channel already conforms; new channels get the echo-loop guard for free. |
| Builders (`MessageBuilder`, `ConversationBuilder`, `ContactInboxWithContactBuilder`) | Encode subtle rules (reply windows, dedupe, `lock_to_single_conversation`). |
| Inbox ↔ Channel polymorphism | The reason channels are cheap to add. |
| Auth stack (devise_token_auth, access tokens, MFA, HMAC widget identity) | Security-critical and well-trodden. |
| Pundit policy layer | Already tenant-aware via `pundit_user`. |
| ActionCable / `RoomChannel` / `ActionCableListener` | Token-addressed fan-out is correct; replacing it is pure risk. |
| Sidekiq queue topology + `MutexApplicationJob` | The mutex/dedupe patterns solve real provider race conditions. |
| Feature-flag system (`Featurable`) | Per-account gating you will need for plans/tiers. |
| Installation config + `GlobalConfig` Redis cache | Runtime-editable settings without deploys. |
| WhatsApp / Instagram / Facebook ingestion pipelines | Years of edge cases (echoes, BSUID rotation, album uploads, coexistence). |
| `components-next/` primitives + Tailwind theme | Your UI should compose these. |
| Public/Platform APIs, Jbuilder views | Stable contracts. |

### 22.2 Customize (the intended surface)

| Area | How |
|---|---|
| **Branding** | `INSTALLATION_NAME`, `LOGO*`, `BRAND_NAME`, `BRAND_URL`, `WIDGET_BRAND_URL`, `TERMS_URL`, `PRIVACY_URL` in installation configs; `public/brand-assets/`; `useBranding().replaceInstallationName` in the UI. |
| **Theme** | `theme/colors.js`, `theme/icons.js`, `tailwind.config.js` extensions. |
| **New UI** | New components under `dashboard/components-next/`; new routes under `dashboard/routes/dashboard/`; new Pinia stores under `dashboard/stores/`. |
| **New backend behaviour** | New listener subscribed in a dispatcher; or a new service + job. |
| **New channel** | New `Channel::X` + webhook controller + events job + incoming service + `SendOnXService` + `CHANNEL_SERVICES` entry. |
| **Integrations** | `config/integration/apps.yml` entry + a processor in `lib/integrations/`. |
| **Outbound webhooks** | Extend `Webhook::ALLOWED_WEBHOOK_EVENTS` and `WebhookListener`. |
| **Tenant provisioning / billing** | Platform API (`/platform/api/v1/accounts`) + `AccountBuilder`, driven from your own control plane. |
| **Plan gating** | Account feature flags (`feature_flags_ext_1` only) + `ACCOUNT_LEVEL_FEATURE_DEFAULTS`. |
| **Agent-facing automation** | `AutomationRule`, `Macro`, `AgentBot` + `Integrations::BotProcessorService` — extend rather than fork. |

### 22.3 Avoid modifying initially

| Area | Risk |
|---|---|
| `enterprise/**` | **Licensing.** Not MIT; modifications are assigned to Chatwoot; production use needs a subscription. |
| `config/features.yml` — existing entries | Bit positions are persisted. Reordering/removing silently corrupts every account's flags. Append to `feature_flags_ext_1` only. |
| `db/migrate/**` existing migrations, `db/schema.rb` | Diverging the schema makes every upstream merge painful. Add new migrations; don't edit old ones. |
| `Message` / `Conversation` / `Account` model callbacks | `execute_after_create_commit_callbacks` is the hub of the send pipeline; reordering breaks delivery, realtime and reporting at once. |
| `Base::SendOnChannelService#invalid_message?` | Weakening the `source_id` check causes infinite message loops with providers. |
| `EnsureCurrentAccountHelper` / `Current` | The entire tenancy boundary. Any change here is a cross-tenant data-leak risk. |
| `config/routes.rb` existing routes | Public API + widget SDK contracts; breaking them breaks embedded customer sites. |
| `app/javascript/dashboard/components/` (legacy) | Being deprecated upstream — work here is thrown away. |
| Vuex store module internals | Widely coupled; prefer new Pinia stores. |
| `config/initializers/01_inject_enterprise_edition_module.rb` | The overlay mechanism itself; use it, don't change it. |
| Provider webhook signature verification (`MetaTokenVerifyConcern`, `HmacConcern`) | Security boundary. |
| `app/javascript/sdk/` (40 KB budget) | Shipped to third-party sites; size-limited and cached widely. |
| `swagger/` | The published API contract. |
| Locale files other than `en.yml` / `en.json` | Crowdin-owned; edits get overwritten. |

---

## 23. Safest extension points for a branded SaaS

Ranked by safety (1 = safest, no upstream conflict).

### 1. The `custom/` overlay directory — *the single best-kept secret in this codebase*

`ChatwootApp.extensions` returns `%w[enterprise custom]` when a top-level `custom/` directory exists
(`lib/chatwoot_app.rb`). Every `prepend_mod_with('Foo')` call already scattered through the OSS code
will then also look for `Custom::Foo`.

```ruby
# custom/app/models/custom/inbox.rb
module Custom::Inbox
  def sanitized_name
    # your override; `super` still available
  end
end
```

This gives you **Ruby-level overrides of models, policies, services, controllers and dispatchers with
essentially zero edits to tracked OSS files**. Mirror the `enterprise/` layout (`custom/app/...`,
`custom/lib/...`).

> **One caveat, verified:** `ChatwootApp.extensions` already supports `custom`, but
> `config/application.rb` (lines 42–48) adds **only** `enterprise/lib`, `enterprise/listeners`,
> `enterprise/app/**` and `enterprise/app/views` to the load paths — **`custom/` is not wired into the
> Rails autoloader.** To use this overlay you must add the mirrored lines yourself:
>
> ```ruby
> config.eager_load_paths << Rails.root.join('custom/lib')
> config.eager_load_paths += Dir["#{Rails.root}/custom/app/**"]
> config.paths['app/views'].unshift('custom/app/views')
> ```
>
> That is a ~3-line edit to one file — by far the cheapest upstream-merge tax available, and it buys
> you override capability across the whole codebase.

Constants that already expose a `*_mod_with` hook include `Account`, `Inbox`, `Conversation`,
`Message`, `Channelable`, `Channel::Whatsapp`, `ConversationPolicy`, `SyncDispatcher`,
`AsyncDispatcher` and `Webhooks::WhatsappEventsJob`. Enumerate the full list with
`rg -n "prepend_mod_with|include_mod_with|extend_mod_with" app lib`.

### 2. Installation configs for all branding

Never hardcode your brand. Set `INSTALLATION_NAME`, `BRAND_NAME`, `LOGO`, `LOGO_DARK`,
`LOGO_THUMBNAIL`, `BRAND_URL`, `WIDGET_BRAND_URL`, `TERMS_URL`, `PRIVACY_URL` via Super Admin or a
seed. In the UI, route user-facing copy through
`useBranding().replaceInstallationName` (`app/javascript/shared/composables/useBranding.js`) as
`AGENTS.md` instructs. Removing the "Powered by" marks in the widget/emails is the
`disable_branding` feature — **a premium (EE) feature**; check licensing before relying on it.

### 3. New listeners on the event bus

Add a listener class and subscribe it in a `Custom::AsyncDispatcher#listeners` override. You get
every domain event (`MESSAGE_CREATED`, `CONVERSATION_*`, `CONTACT_*`, `INBOX_*`, `AGENT_*`) without
touching a single model callback. Use this for usage metering, billing events, analytics, and custom
notifications.

### 4. Platform API as your control plane

`/platform/api/v1/accounts`, `/users`, `/account_users`, `/agent_bots` with a `PlatformApp` token.
Provision tenants, seats and bots from your own signup/billing app instead of forking `AccountBuilder`
or the signup UI. Set `ENABLE_ACCOUNT_SIGNUP=api_only` to disable the built-in signup UI while keeping
programmatic account creation.

### 5. Per-account feature flags for plan tiers

Append your flags to `config/features.yml` with `column: feature_flags_ext_1`, gate UI with
`dashboard/featureFlags.js`, and gate backend with `account.feature_enabled?('your_flag')`. Drive the
defaults from `ACCOUNT_LEVEL_FEATURE_DEFAULTS`. This is how Chatwoot itself does plan gating, so it
will keep working across upgrades.

### 6. `components-next/` + Tailwind theme for UI

New screens as new components in `components-next/` + new route folders. Theme via `theme/colors.js`
and `tailwind.config.js` rather than overriding component internals. Histoire stories keep the new
pieces documented.

### 7. Integrations catalogue for third-party features

A YAML entry in `config/integration/apps.yml` plus a processor under `lib/integrations/` gives you a
settings form, an account/inbox-scoped `Integrations::Hook` with JSON-schema validation, and event
delivery through `HookListener` — no core changes at all.

### 8. Outbound webhooks / AgentBot for anything external

Before writing Rails code, ask whether an `AgentBot` (webhook-driven, per-inbox) or an account
webhook can do the job. Both are first-class, both survive upgrades.

### 9. New channels via the documented seams

Follow the six-file recipe in §8.3. If you need to make it available through the generic inbox-create
API, that means touching `allowed_channel_types` — do that as a `Custom::` controller override rather
than editing the OSS controller.

---

### Upgrade-safety rules of thumb

1. **Add files; don't edit tracked ones.** Prefer `custom/` overlays, new listeners, new services.
2. **Never touch the tenancy boundary** (`EnsureCurrentAccountHelper`, `Current`, `pundit_user`).
3. **Never reorder feature flags or edit shipped migrations.**
4. **Treat `enterprise/` as third-party licensed code** — read `enterprise/LICENSE` before depending
   on anything it contains, and consider `DISABLE_ENTERPRISE=true` if you cannot license it.
5. **Keep a merge diary**: every OSS file you do end up editing is a permanent merge-conflict tax.

---

*End of audit. No application files were modified in producing this document.*
