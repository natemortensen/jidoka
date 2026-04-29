# Jidoka

Jidoka is a Ruby gem for building **Workers** and **Supervisors** — service objects that encapsulate business operations with built-in validation, rollback, and notification. It is the Command pattern with a focus on reversibility and atomic, multi-step workflows.

The name comes from the lean-manufacturing principle of *jidoka* ("autonomation"): a process that detects an abnormality and stops itself rather than producing defects. A Jidoka `Worker` validates before it acts, executes inside a transaction, and knows how to undo itself if anything downstream fails.

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'jidoka'
```

And then execute:

```
$ bundle install
```

Or install it yourself as:

```
$ gem install jidoka
```

## Configuration

Add an initializer:

```ruby
# config/initializers/jidoka.rb
Jidoka.configure do |config|
  # Inherit from your app's base job to get queues, retries, etc.
  config.parent_job_class = "ApplicationJob"

  # Hook into your error reporting tool
  config.error_handler = ->(e, context) {
    if defined?(Sentry)
      Sentry.set_context("jidoka", context)
      Sentry.capture_exception(e)
      Sentry::Context.clear!
    else
      Rails.logger.error("Jidoka Error: #{e.message} Context: #{context}")
    end
  }
end
```

Because Workers inherit from `ActiveJob::Base` (or whatever you set as `parent_job_class`), the same class can be invoked synchronously (`run!`) or enqueued (`perform_later`).

-----

## Overview

Jidoka provides two primary building blocks:

1. **`Jidoka::Worker`** — encapsulates a single, focused business operation
2. **`Jidoka::Supervisor`** — coordinates multiple Workers (and inline steps) into one atomic workflow

Both layers give you:

- **Reversibility** — every action can be undone via `down`
- **Validation** — business rules run before any side effect
- **Testability** — each component is exercised in isolation
- **Notifications** — emails / SMS / webhooks live in their own hook, separate from execution
- **Atomicity** — Supervisor steps roll back automatically when a later step fails

-----

## Workers

A `Worker` is a single-purpose service object. It validates inputs, performs the operation in a transaction, and knows how to undo itself.

### When to use a Worker

Reach for a Worker when you need to:

- Perform a non-trivial business action beyond plain CRUD
- Validate business rules before mutating state
- Provide rollback for an operation
- Fire notifications after a successful action
- Keep controller and job code thin

### Worker structure

```ruby
class PublishArticle < Jidoka::Worker
  attr_reader :article

  # 1. User-facing error messages (keys are referenced by `condition!` / `fail!`)
  ERRORS = {
    not_a_draft:       "Only draft articles can be published",
    missing_cover:     "An article needs a cover image before publishing",
    publisher_blocked: "This author is not allowed to publish right now"
  }.freeze

  # 2. Argument type validation (optional)
  enforce_arguments!(
    article: "Article",
    author:  "User"
  )

  # 3. Set instance variables before validation runs (optional)
  def prepare(article:, author:, **_opts)
    @article = article
    @author  = author
  end

  # 4. Business rules (optional)
  def validate_conditions!(article:, author:, **_opts)
    condition!(:not_a_draft)       { article.draft? }
    condition!(:missing_cover)     { article.cover_image.attached? }
    condition!(:publisher_blocked) { author.can_publish? }
  end

  # 5. The actual work (REQUIRED)
  def up(article:, **_opts)
    article.update!(status: :published, published_at: Time.current)
  end

  # 6. Rollback (optional, but strongly recommended)
  def down
    @article.update!(status: :draft, published_at: nil)
  end

  # 7. Notifications (optional)
  def _notify(article:, **_opts)
    ArticleMailer.published(article).deliver_later
  end
end
```

### Executing a Worker

**With exceptions** (preferred when you want failures to surface as errors):

```ruby
PublishArticle.run!(article: article, author: current_user)

# Validate without executing
PublishArticle.dry_run!(article: article, author: current_user)
```

**Without exceptions** (preferred when you want to branch on success/failure):

```ruby
result = PublishArticle.run(article: article, author: current_user)

if result.success?
  redirect_to result.article
else
  flash[:error] = result.message
  render :edit
end

# Or with the block form
PublishArticle.run(article: article, author: current_user) do |result|
  result.success { |r| redirect_to r.article }
  result.failed  { |r| flash.now[:error] = r.message and render :edit }
end
```

**Skip notifications:**

```ruby
PublishArticle.run!(article: article, author: current_user, notify: false)
```

**As a background job** (Workers inherit from your `parent_job_class`):

```ruby
PublishArticle.perform_later(article: article, author: current_user)
```

### Running outside a transaction

By default `run!` wraps `up` in `ActiveRecord::Base.transaction`. When the work crosses non-transactional boundaries — calling an external API, kicking off a long-running batch, touching a queue — holding a database transaction open is a liability. The wrapping is done by a `with_transaction` instance method; override it to opt out:

```ruby
class SyncSubscriberToMailchimp < Jidoka::Worker
  enforce_arguments!(user: "User")

  # Run `up` directly, without a database transaction around it.
  def with_transaction
    yield
  end

  def up(user:, **_opts)
    Mailchimp.upsert_subscriber(user.email, tags: user.tags)
  end
end
```

Callers still invoke the Worker the normal way:

```ruby
SyncSubscriberToMailchimp.run!(user: user)
SyncSubscriberToMailchimp.run(user: user)
```

Validation and notification still fire — only the transaction wrapper around `up` (and `down`) is skipped.

### Failure semantics

Two flavors of failure:

- **`condition!`** — raises `Jidoka::ConditionNotMet` from `validate_conditions!`. The right tool for "you can't do this yet" pre-flight checks.
- **`fail!`** — raises `Jidoka::Failure` from inside `up`. The right tool for "we tried, it didn't work" runtime errors (e.g. payment gateway said no).

```ruby
def validate_conditions!(order:, **_opts)
  condition!(:not_payable) { order.balance.positive? }
end

def up(order:, **_opts)
  response = PaymentGateway.charge(order.total)
  fail!(:gateway_declined, context: { response_code: response.code }) unless response.success?
end
```

Both attach a namespaced `code` (e.g. `publish_article-not_a_draft`) so callers can branch on specific failures without string-matching on messages.

### Testing a Worker

Cover happy path, every validation branch, and the rollback. RSpec example:

```ruby
RSpec.describe PublishArticle do
  let(:author)  { create(:user, :publisher) }
  let(:article) { create(:article, :draft, :with_cover, author: author) }

  subject { described_class.run(article: article, author: author) }

  it { is_expected.to be_success }

  it "publishes the article" do
    expect { subject }.to change { article.reload.status }.from("draft").to("published")
  end

  context "when the article is already published" do
    let(:article) { create(:article, :published, author: author) }

    it { is_expected.to be_failure }
    it { expect(subject.error).to be_a(Jidoka::ConditionNotMet) }
    it { expect(subject.error.code).to eq("publish_article-not_a_draft") }
  end

  context "when the cover image is missing" do
    let(:article) { create(:article, :draft, author: author) }

    it { expect(subject.error.code).to eq("publish_article-missing_cover") }
  end
end
```

-----

## Supervisors

A `Supervisor` runs an ordered list of steps as a single atomic unit. If any step raises, every prior step is rolled back in reverse order.

### When to use a Supervisor

Reach for a Supervisor when you need to:

- Combine multiple Workers (or ad-hoc operations) into one logical action
- Get all-or-nothing semantics across heterogeneous side effects
- Coordinate changes that touch several aggregates / models
- Define a rollback sequence that mirrors a forward sequence

### Supervisor structure

```ruby
class OnboardCustomer < Jidoka::Supervisor
  attr_reader :account, :membership, :welcome_message

  ERRORS = {
    email_taken:      "That email is already in use",
    plan_unavailable: "The selected plan is not currently available"
  }.freeze

  enforce_arguments!(
    email: "String",
    plan:  "Plan"
  )

  def prepare(email:, plan:, **_opts)
    @email = email
    @plan  = plan
  end

  def validate_conditions!(email:, plan:, **_opts)
    condition!(:email_taken)      { !User.exists?(email: email) }
    condition!(:plan_unavailable) { plan.available? }
  end

  def orchestrate(email:, plan:, **_opts)
    # 1. Create the account, undo on rollback
    @account = create_record_step! { Account.create!(email: email) }

    # 2. Update the plan's seat count, restore on rollback
    update_record_step!(plan, seats_taken: plan.seats_taken + 1)

    # 3. Run another Worker as a step — its own `down` will be called on rollback
    @membership = worker_step!(GrantMembership, account: @account, plan: plan).membership

    # 4. Inline step with explicit up/down/notify
    step! do
      up     { @welcome_message = WelcomeMessageBuilder.build(@account) }
      down   { |msg| msg&.discard! }
      notify { |msg| ChatOps.post("New signup: #{msg.preview}") }
    end
  end

  def _notify(email:, **_opts)
    OnboardingMailer.welcome(email).deliver_later
  end
end
```

`orchestrate` is the Supervisor equivalent of `up` — it is required, and it is what defines the workflow.

### Step helpers

#### `step!` — fully manual

The primitive every other helper is built on. Provide any combination of `up`, `down`, and `notify`. The result of `up` is passed as the argument to `down` and `notify`:

```ruby
step! do
  up     { ExternalAPI.charge(order) }
  down   { |response| ExternalAPI.refund(response.transaction_id) if response }
  notify { |response| AuditLog.record(response.transaction_id) }
end
```

#### `worker_step!` — run a Worker as a step

Runs another Worker, with the Worker's own `down` and `notify!` wired up automatically:

```ruby
def orchestrate(order:, **_opts)
  # The return value of run! (the Worker instance) is the step's result
  @payout = worker_step!(GeneratePayout, order: order).payout

  # Suppress the Worker's notifications for this call
  worker_step!(SendReceipt, order: order, notify: false)
end
```

How it works:

- Calls `Worker.run!` (raises on failure, which triggers Supervisor rollback)
- Default `down` calls `down` on the returned Worker instance
- Default `notify` calls `notify!` on the returned Worker instance, unless `notify: false`

**Overriding `down` and `notify`.** `worker_step!` accepts an optional block using the same DSL as `step!`. Anything you set in the block overrides the defaults — useful when the surrounding workflow requires a different rollback or notification path than the Worker provides on its own:

```ruby
worker_step!(ChargePayment, order: order) do
  # Replace the Worker's default `down` with a custom refund flow
  down { |worker| RefundPayment.run!(charge_id: worker.charge_id, reason: :rolled_back) }

  # Replace the Worker's default `notify!` with a richer audit message
  notify { |worker| AuditLog.record(charge_id: worker.charge_id, supervisor: self.class.name) }
end
```

You can also override `up` if you need to swap in different invocation semantics for that Worker — for example, instantiating it directly to bypass the standard validate/run/notify pipeline:

```ruby
worker_step!(ChargePayment, order: order) do
  up { ChargePayment.new(order: order, idempotency_key: SecureRandom.uuid).tap(&:run!) }
end
```

#### `update_record_step!` — update with auto-restore

Captures the record's current attribute values, applies updates, and on rollback restores them:

```ruby
update_record_step!(order, status: :accepted, accepted_at: Time.current)
update_record_step!(user, last_seen_at: Time.current)
```

Nested attributes (`*_attributes`) are handled by resetting to a fresh instance of their class on rollback.

#### `create_record_step!` — create with auto-destroy

Runs a block that returns a newly created record. On rollback, the record is reloaded and destroyed:

```ruby
@invoice = create_record_step! { order.invoices.create!(amount: order.total) }
```

### Testing a Supervisor

Focus on three things: that the steps run, that rollback unwinds them in reverse, and that validation gates work.

```ruby
RSpec.describe OnboardCustomer do
  let(:plan) { create(:plan, seats_taken: 0) }

  subject { described_class.run(email: "new@example.com", plan: plan) }

  context "happy path" do
    it { is_expected.to be_success }
    it { expect { subject }.to change(Account, :count).by(1) }
    it { expect { subject && plan.reload }.to change(plan, :seats_taken).by(1) }
  end

  context "when a later step blows up" do
    before do
      allow(GrantMembership).to receive(:run!).and_raise(StandardError, "boom")
    end

    it { is_expected.to be_failure }

    it "rolls back the account creation" do
      expect { subject }.not_to change(Account, :count)
    end

    it "restores the plan's seat count" do
      expect { subject && plan.reload }.not_to change(plan, :seats_taken)
    end
  end

  context "when the email is taken" do
    before { create(:user, email: "new@example.com") }

    it { is_expected.to be_failure }
    it { expect(subject.error.code).to eq("onboard_customer-email_taken") }
  end
end
```

-----

## Best practices

1. **Keep Workers focused.** One Worker, one operation. If the description has an "and" in it, it probably wants to be a Supervisor.
2. **Always implement `down`.** Unless the operation is genuinely irreversible (e.g. an external email already sent), define a rollback. Supervisors lean hard on it.
3. **Validate early.** All gating belongs in `validate_conditions!`. Don't sneak `condition!` calls into `up`.
4. **Use specific error keys.** `:order_not_accepted` is better than `:invalid`. Keys end up in the namespaced `error.code`, which is the stable identifier callers branch on.
5. **Expose results via `attr_reader`.** Anything a caller will need (`@payout`, `@membership`) should be readable on the returned instance.
6. **Don't enqueue inside `orchestrate`.** Background jobs trigger after the Supervisor finishes — fire them from `_notify`, where their effects won't be rolled back.

### Worker vs. Supervisor

| Use a Worker when… | Use a Supervisor when… |
| --- | --- |
| You're performing one focused operation | You're combining several operations |
| Changes touch primarily one aggregate | Changes touch multiple aggregates |
| Rollback is straightforward | You need an ordered, reversible sequence |
| Examples: send a message, generate a payout, mark something delivered | Examples: onboard a customer, accept an order, complete a checkout |

### Naming

- **Workers** are verbs: `PublishArticle`, `GeneratePayout`, `RefundOrder`
- **Supervisors** are also verbs, usually for higher-level flows: `OnboardCustomer`, `CheckoutCart`, `AcceptOrder`

-----

## Common patterns

### Conditional steps

```ruby
def orchestrate(order:, send_receipt: true, **_opts)
  update_record_step!(order, status: :confirmed)
  worker_step!(SendReceipt, order: order) if send_receipt
  worker_step!(ChargePayment, order: order) if order.requires_payment?
end
```

### Composing Workers

```ruby
class ProvisionTeam < Jidoka::Supervisor
  def orchestrate(team_fields:, owner_fields:, **_opts)
    @team  = worker_step!(CreateTeam, team_fields).team
    @owner = worker_step!(CreateUser, owner_fields.merge(team: @team)).user
    worker_step!(GrantOwnerPermissions, team: @team, user: @owner)
  end
end
```

### Talking to external APIs

External calls don't roll back automatically — design the `down` to be best-effort and never re-raise:

```ruby
class ChargeCard < Jidoka::Worker
  attr_reader :charge_id

  def up(order:, **_opts)
    response = PaymentGateway.charge(order.total)
    fail!(:gateway_declined, context: { code: response.code }) unless response.success?

    @charge_id = response.charge_id
    order.update!(charge_id: @charge_id)
  end

  def down
    PaymentGateway.refund(@charge_id) if @charge_id
  rescue StandardError => e
    # Refund failures shouldn't cascade — log and move on, the rest of the
    # rollback still needs to run.
    Rails.logger.error("Failed to refund #{@charge_id}: #{e.message}")
  end
end
```

### Dry runs for pre-flight checks

```ruby
result = PublishArticle.dry_run(article: article, author: current_user)

if result.success?
  PublishArticle.run!(article: article, author: current_user)
else
  render json: { error: result.message, code: result.error.code }, status: :unprocessable_entity
end
```

### Mixing transactional and non-transactional work

When a Supervisor calls out to a non-transactional system mid-flow, the Worker that owns that call defines its own `with_transaction` to opt out — the rest of the Supervisor's steps stay wrapped as usual:

```ruby
class SyncSubscriberToMailchimp < Jidoka::Worker
  def with_transaction
    yield
  end

  def up(user:, **_opts)
    Mailchimp.upsert_subscriber(user.email)
  end
end

class OnboardCustomer < Jidoka::Supervisor
  def orchestrate(user:, **_opts)
    update_record_step!(user, sync_state: :pending)
    worker_step!(SyncSubscriberToMailchimp, user: user)
    update_record_step!(user, sync_state: :synced)
  end
end
```

-----

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and tags, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/[USERNAME]/jidoka.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
