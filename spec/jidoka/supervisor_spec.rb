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
    let(:flags) { {run_twice: false} }

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
    let(:flags) { {raise_error: true} }

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
      let(:flags) { {raise_inline_error: true} }

      it { expect(subject.inline_step).to match(status: :rolled_back) }
      it { is_expected.not_to be_success }
      it { is_expected.to be_failure }
      it { expect(subject.result).to be_nil }
      it { expect(subject && notification_queue).not_to match(array_including('Hey you! Something happened.')) }
    end
  end
end
