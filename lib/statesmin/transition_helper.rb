require_relative "exceptions"

module Statesmin
  module TransitionHelper
    # Methods to delegate to `state_machine`
    DELEGATED_METHODS = [:allowed_transitions, :can_transition_to?,
                         :current_state, :in_state?].freeze

    # Delegate the methods
    DELEGATED_METHODS.each do |method_name|
      module_eval <<-RUBY, __FILE__, __LINE__ + 1
        def #{method_name}(*args)
          state_machine.#{method_name}(*args)
        end
      RUBY
    end

    def transition_to!(next_state, data = {})
      raise_transition_not_defined_error unless respond_to?(:transition, false)
      state_machine.transition_to!(next_state, data) do
        transition(next_state, data)
      end
    end

    def transition_to(next_state, data = {})
      transition_to!(next_state, data)
    rescue Statesmin::TransitionFailedError, Statesmin::GuardFailedError
      false
    end

    private

    def state_machine
      raise Statesmin::NotImplementedError.new('state_machine', self.class.name)
    end

    def raise_transition_not_defined_error
      raise Statesmin::NotImplementedError.new('transition', self.class.name)
    end
  end
end
