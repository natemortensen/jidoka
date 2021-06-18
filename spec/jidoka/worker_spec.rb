RSpec.describe MockClasses::TestWorker do
  let!(:arr) { %i[one] }
  let!(:notifications) { [] }

  let(:args) do
    {
      arr: arr,
      notifications: notifications
    }
  end

  describe 'run!' do
    subject { described_class.run!(args) }

    it { is_expected.to be_an_instance_of(described_class) }
    it { expect { subject }.to change(arr, :size).by(1) }
    it { expect { subject }.to change(notifications, :size).by(1) }
    it do
      is_expected.to have_attributes(
        arr: [:one, 'Code has executed.'],
        message: nil
      )
    end

    context 'with invalid args' do
      let(:arr) { %i[one two] }

      it { expect { subject rescue nil }.not_to change(arr, :size) }
      it { expect { subject rescue nil }.not_to change(notifications, :size) }
      it { expect { subject }.to raise_error(Jidoka::ConditionNotMet) }
    end
  end

  describe 'run' do
    subject { described_class.run(args) }

    it { is_expected.to be_an_instance_of(described_class) }
    it { expect { subject }.to change(arr, :size).by(1) }
    it { expect { subject }.to change(notifications, :size).by(1) }
    it do
      is_expected.to have_attributes(
        arr: [:one, 'Code has executed.'],
        message: nil
      )
    end

    context 'with invalid args' do
      let(:arr) { %i[one two] }

      it { expect { subject }.not_to change(arr, :size) }
      it { expect { subject }.not_to change(notifications, :size) }
      it { expect { subject }.not_to raise_error(Jidoka::ConditionNotMet) }

      it do
        is_expected.to be_failure.and have_attributes(
          arr: %i[one two],
          message: 'Array cannot have multiple elements'
        )
      end
    end
  end

  describe 'dry_run!' do
    subject { described_class.dry_run!(args) }

    it { is_expected.to be_an_instance_of(described_class) }
    it { expect { subject }.not_to change(arr, :size) }
    it { expect { subject }.not_to change(notifications, :size) }
    it do
      is_expected.to be_success.and have_attributes(
        arr: %i[one],
        message: nil
      )
    end

    context 'with invalid args' do
      let(:arr) { %i[one two] }

      it { expect { subject rescue nil }.not_to change(arr, :size) }
      it { expect { subject rescue nil }.not_to change(notifications, :size) }
      it { expect { subject }.to raise_error(Jidoka::ConditionNotMet) }
    end
  end

  describe 'dry_run' do
    subject { described_class.dry_run(args) }

    it { is_expected.to be_an_instance_of(described_class) }
    it { expect { subject }.not_to change(arr, :size) }
    it { expect { subject }.not_to change(notifications, :size) }

    it { is_expected.to be_success }
    it do
      is_expected.to have_attributes(
        arr: %i[one],
        message: nil
      )
    end

    context 'with invalid args' do
      let(:arr) { %i[one two] }


      it { expect { subject }.not_to change(arr, :size) }
      it { expect { subject }.not_to change(notifications, :size) }
      it { expect { subject }.not_to raise_error(Jidoka::ConditionNotMet) }

      it { is_expected.to be_failure }
      it do
        is_expected.to have_attributes(
          arr: %i[one two],
          message: 'Array cannot have multiple elements'
        )
      end
    end
  end
end