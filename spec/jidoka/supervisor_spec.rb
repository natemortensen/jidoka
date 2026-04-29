# frozen_string_literal: true

RSpec.describe MockClasses::TestSupervisor do
  let(:flags) { {} }
  let!(:input_array) { [] }
  let!(:notification_queue) { [] }

  subject do
    described_class.run(
      flags.merge(
        arr: input_array,
        notifications: notification_queue
      )
    )
  end

  context 'without any flags' do
    it { is_expected.to be_success }
    it { is_expected.not_to be_failure }
    it { expect(subject.result).not_to eq(input_array) }
    it { expect(subject.result).to match(array_including('The returned object is slightly different')) }
    it { expect(subject && input_array).not_to match(array_including('The returned object is slightly different')) }
    it { expect(subject && input_array).to match(array_including('Code has executed.')) }
    it { expect(subject && notification_queue).to match(array_including('Hey you! Something happened.')) }
    it { expect { subject }.to change(input_array, :size).from(0).to(2) }
    it { expect { subject }.to change(notification_queue, :size).from(0).to(2) }
  end

  context 'with a conditional flag' do
    let(:flags) { { run_twice: false } }

    it { is_expected.to be_success }
    it { is_expected.not_to be_failure }
    it { expect(subject.result).not_to eq(input_array) }
    it { expect(subject.result).to match(array_including('The returned object is slightly different')) }
    it { expect(subject && input_array).not_to match(array_including('The returned object is slightly different')) }
    it { expect(subject && input_array).to match(array_including('Code has executed.')) }
    it { expect(subject && notification_queue).to match(array_including('Hey you! Something happened.')) }
    it { expect { subject }.to change(input_array, :size).from(0).to(1) }
    it { expect { subject }.to change(notification_queue, :size).from(0).to(1) }
  end

  context 'when one of the steps fails' do
    let(:flags) { { raise_error: true } }

    it { is_expected.not_to be_success }
    it { is_expected.to be_failure }
    it { expect(subject.message).to eq('Array cannot have multiple elements') }
    it { expect { subject }.not_to change(input_array, :size).from(0) }
    it { expect { subject }.not_to change(notification_queue, :size).from(0) }
  end

  context 'when the orchestrator validation fails' do
    let!(:input_array) { [false] }

    it { is_expected.not_to be_success }
    it { is_expected.to be_failure }
    it { expect(subject.message).to eq('Array is not empty') }
    it { expect { subject }.not_to change(input_array, :size).from(1) }
    it { expect { subject }.not_to change(notification_queue, :size).from(0) }
  end

  describe 'inline steps' do
    it { expect(subject.inline_step).to match(status: :ran) }
    it { is_expected.to be_success }
    it { is_expected.not_to be_failure }
    it { expect(subject.result).not_to match(input_array) }
    it { expect(subject.result).to match(array_including('The returned object is slightly different')) }
    it { expect(subject && notification_queue).to match(array_including('Hey you! Something happened.')) }

    context 'when a failure happens after the step' do
      let(:flags) { { raise_inline_error: true } }

      it { expect(subject.inline_step).to match(status: :rolled_back) }
      it { is_expected.not_to be_success }
      it { is_expected.to be_failure }
      it { expect(subject.result).to be_nil }
      it { expect(subject && notification_queue).not_to match(array_including('Hey you! Something happened.')) }
    end
  end
end

RSpec.describe MockClasses::WorkerStepOverrideSupervisor do
  let!(:input_array) { [] }
  let!(:notification_queue) { [] }
  let!(:down_log) { [] }
  let!(:notify_log) { [] }
  let(:flags) { {} }

  subject do
    described_class.run(
      flags.merge(
        arr: input_array,
        notifications: notification_queue,
        down_log: down_log,
        notify_log: notify_log
      )
    )
  end

  context 'on success' do
    it { is_expected.to be_success }

    it 'invokes the overridden notify block instead of the default' do
      subject
      expect(notify_log).to eq([:custom_notify])
      expect(notification_queue).to be_empty
    end

    it 'does not invoke the down block when no rollback occurs' do
      subject
      expect(down_log).to be_empty
    end
  end

  context 'when a later failure triggers rollback' do
    let(:flags) { { raise_after: true } }

    it { is_expected.to be_failure }

    it 'invokes the overridden down block instead of the default' do
      subject
      expect(down_log).to eq([:custom_down])
      # Default down would have popped from input_array; the override does not.
      expect(input_array).to eq(['Code has executed.'])
    end

    it 'does not fire notify when the supervisor fails' do
      subject
      expect(notify_log).to be_empty
    end
  end
end

RSpec.describe 'forward-recovery via down registered before up' do
  let(:supervisor_class) do
    Class.new(Jidoka::Supervisor) do
      def orchestrate(recovery_log:, **_opts)
        step! do
          down { recovery_log << :recovered }
          up { raise 'up failed mid-flight' }
        end
      end
    end
  end

  it 'invokes down when up raises, allowing forward-recovery' do
    log = []
    result = supervisor_class.run(recovery_log: log)
    expect(result).to be_failure
    expect(log).to eq([:recovered])
  end
end
