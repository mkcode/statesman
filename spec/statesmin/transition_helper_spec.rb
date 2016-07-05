require "spec_helper"

describe Statesmin::TransitionHelper do
  let(:transition_class)  { Class.new { include Statesmin::TransitionHelper } }
  let(:state_machine) do
    Class.new do
      include Statesmin::Machine
      state :x, initial: true
      state :y
      transition from: :x, to: :y
    end.new(Object.new)
  end
  let(:instance) do
    transition_class.new.tap do |instance|
      allow(instance).to receive(:state_machine).and_return(state_machine)
    end
  end

  context 'delegated methods' do
    context 'when no state_machine method is defined' do
      let(:unimplemented_instance) { transition_class.new }

      Statesmin::TransitionHelper::DELEGATED_METHODS.each do |method|
        describe "##{method}" do
          it 'raises a NotImplementedError' do
            expect { unimplemented_instance.send(method) }.
              to raise_error(Statesmin::NotImplementedError)
          end
        end
      end
    end

    context 'when a state_machine method is defined' do
      Statesmin::TransitionHelper::DELEGATED_METHODS.each do |method|
        describe "##{method}" do
          it 'calls that method on the state_machine' do
            needs_arg = state_machine.method(method).arity == 0
            expect(state_machine).to receive(method)
            needs_arg ? instance.send(method) : instance.send(method, :y)
          end
        end
      end
    end
  end

  shared_examples 'a transition method' do |method|
    context 'when no transition method is defined' do
      it 'raises a NotImplementedError' do
        expect { instance.send(method, :y) }.
          to raise_error(Statesmin::NotImplementedError)
      end
    end

    context 'when a transition method is defined' do
      before do
        instance.define_singleton_method :transition, -> (_state, _) { nil }
      end

      context 'when the next_state argument is a valid transition' do
        it 'calls the transition method' do
          expect(instance).to receive(:transition)
          instance.send(method, :y)
        end

        it 'updates the current_state of the state_machine' do
          instance.send(method, :y)
          expect(state_machine.current_state).to eq('y')
        end

        it 'returns the value of the transition method' do
          allow(instance).to receive(:transition).and_return(42)
          expect(instance.send(method, :y)).to eq(42)
        end
      end
    end
  end

  describe '#transition_to!' do
    it_behaves_like 'a transition method', :transition_to!

    context 'when a valid transition method is defined' do
      before do
        instance.define_singleton_method :transition, -> (_state, _) { nil }
      end

      context 'and the next_state argument is not a valid transition' do
        it 'raises a TransitionFailedError' do
          expect { instance.transition_to!(:z) }.
            to raise_error(Statesmin::TransitionFailedError)
        end

        it 'does not call the transition method' do
          expect(instance).to_not receive(:transition)
          expect { instance.transition_to!(:z) }.to raise_error
        end

        it 'does not update the current_state of the state_machine' do
          expect { instance.transition_to!(:z) }.to raise_error
          expect(state_machine.current_state).to eq('x')
        end
      end
    end

    context 'when a error raising transition method is defined' do
      before do
        instance.define_singleton_method :transition, -> (_state, _) { raise }
      end

      context 'and the next_state argument is a valid' do
        it 'raises a RuntimeError' do
          expect { instance.transition_to!(:y) }.to raise_error(RuntimeError)
        end
      end
    end
  end

  describe '#transition_to' do
    it_behaves_like 'a transition method', :transition_to

    context 'when a valid transition method is defined' do
      before do
        instance.define_singleton_method :transition, -> (_state, _) { nil }
      end

      context 'and the next_state argument is not a valid transition' do
        it 'returns false' do
          expect(instance.transition_to(:z)).to eq(false)
        end

        it 'does not call the transition method' do
          expect(instance).to_not receive(:transition)
          instance.transition_to(:z)
        end

        it 'does not update the current_state of the state_machine' do
          instance.transition_to(:z)
          expect(state_machine.current_state).to eq('x')
        end
      end
    end

    context 'when a transition method raises a RuntimeError' do
      before do
        instance.define_singleton_method :transition do |_state, _|
          raise RuntimeError
        end
      end

      context 'and the next_state argument is a valid' do
        it 'raises a RuntimeError' do
          expect { instance.transition_to(:y) }.to raise_error(RuntimeError)
        end
      end
    end

    context 'when a transition method raises a TransitionFailedError' do
      before do
        instance.define_singleton_method :transition do |_state, _|
          raise Statesmin::TransitionFailedError
        end
      end

      context 'and the next_state argument is a valid' do
        it 'returns false' do
          expect(instance.transition_to(:y)).to eq(false)
        end
      end
    end
  end
end
