## Statesmin

[![Build Status](https://travis-ci.org/mkcode/statesmin.svg?branch=master)](https://travis-ci.org/mkcode/statesmin)

Statesmin is a fork of [stateman](https://github.com/gocardless/statesman) that
uses a machete to rip out all of the database related code leaving you with a
simple, robust, and well tested DSL for defining state machines in your
application.

The following is an adapted version of the original Statesmin README.

---

![Statesmin](http://f.cl.ly/items/410n2A0S3l1W0i3i0o2K/statesman.png)

A statesmanlike state machine library for Ruby 2.0.0 and up.

Statesmin is an opinionated state machine library designed to provide a robust
audit trail and data integrity. It decouples the state machine logic from the
underlying model and allows for easy composition with one or more model classes.

As such, the design of statesman is a little different from other state machine
libraries:
- State behaviour is defined in a separate, "state machine" class, rather than
added directly onto a model. State machines are then instantiated with the model
to which they should apply.
- ~~State transitions are also modelled as a class, which can optionally be
persisted to the database for a full audit history. This audit history can
include JSON metadata set during a transition.~~
- ~~Database indices are used to offer database-level transaction duplication
protection.~~
- Free to define your own transition logic for your application!

## TL;DR Usage

```ruby

#######################
# State Machine Class #
#######################
class OrderStateMachine
  include Statesmin::Machine

  state :pending, initial: true
  state :checking_out
  state :purchased
  state :shipped
  state :cancelled
  state :failed
  state :refunded

  transition from: :pending,      to: [:checking_out, :cancelled]
  transition from: :checking_out, to: [:purchased, :cancelled]
  transition from: :purchased,    to: [:shipped, :failed]
  transition from: :shipped,      to: :refunded

  guard_transition(to: :checking_out) do |order|
    order.products_in_stock?
  end

  before_transition(from: :checking_out, to: :cancelled) do |order, transition|
    order.reallocate_stock
  end

  before_transition(to: :purchased) do |order, transition|
    PaymentService.new(order).submit
  end

  after_transition(to: :purchased) do |order, transition|
    MailerService.order_confirmation(order).deliver
  end
end

##############
# Your Model #
##############
class Order < ActiveRecord::Base
  include Statesmin::Adapters::ActiveRecordQueries

  has_many :order_transitions, autosave: false

  def state_machine
    @state_machine ||= OrderStateMachine.new(self, transition_class: OrderTransition)
  end

  def self.transition_class
    OrderTransition
  end
  private_class_method :transition_class

  def self.initial_state
    :pending
  end
  private_class_method :initial_state
end

####################
# Transition Model #
####################
class OrderTransition < ActiveRecord::Base
  include Statesmin::Adapters::ActiveRecordTransition

  belongs_to :order, inverse_of: :order_transitions
end

########################
# Example method calls #
########################
Order.first.state_machine.current_state # => "pending"
Order.first.state_machine.allowed_transitions # => ["checking_out", "cancelled"]
Order.first.state_machine.can_transition_to?(:cancelled) # => true/false
Order.first.state_machine.transition_to(:cancelled, optional: :metadata) # => true/false
Order.first.state_machine.transition_to!(:cancelled) # => true/exception

Order.in_state(:cancelled) # => [#<Order id: "123">]
Order.not_in_state(:checking_out) # => [#<Order id: "123">]

```


## Class methods

#### `Machine.state`
```ruby
Machine.state(:some_state, initial: true)
Machine.state(:another_state)
```
Define a new state and optionally mark as the initial state.

#### `Machine.transition`
```ruby
Machine.transition(from: :some_state, to: :another_state)
```
Define a transition rule. Both method parameters are required, `to` can also be
an array of states (`.transition(from: :some_state, to: [:another_state, :some_other_state])`).

#### `Machine.guard_transition`
```ruby
Machine.guard_transition(from: :some_state, to: :another_state) do |object|
  object.some_boolean?
end
```
Define a guard. `to` and `from` parameters are optional, a nil parameter means
guard all transitions. The passed block should evaluate to a boolean and must
be idempotent as it could be called many times.

#### `Machine.before_transition`
```ruby
Machine.before_transition(from: :some_state, to: :another_state) do |object|
  object.side_effect
end
```
Define a callback to run before a transition. `to` and `from` parameters are
optional, a nil parameter means run before all transitions. This callback can
have side-effects as it will only be run once immediately before the transition.

#### `Machine.after_transition`
```ruby
Machine.after_transition(from: :some_state, to: :another_state) do |object, transition|
  object.side_effect
end
```
Define a callback to run after a successful transition. `to` and `from`
parameters are optional, a nil parameter means run after all transitions. The
model object and transition object are passed as arguments to the callback.
This callback can have side-effects as it will only be run once immediately
after the transition.

If you specify `after_commit: true`, the callback will be executed once the
transition has been committed to the database.

#### `Machine.new`
```ruby
my_machine = Machine.new(my_model)
```
Initialize a new state machine instance. `my_model` is required.

#### `Machine.retry_conflicts`
```ruby
Machine.retry_conflicts { instance.transition_to(:new_state) }
```
Automatically retry the given block if a `TransitionConflictError` is raised.
If you know you want to retry a transition if it fails due to a race condition
call it from within this block. Takes an (optional) argument for the maximum
number of retry attempts (defaults to 1).

## Instance methods

#### `Machine#current_state`
Returns the current state based on existing transition objects.

#### `Machine#in_state?(:state_1, :state_2, ...)`
Returns true if the machine is in any of the given states.

#### `Machine#allowed_transitions`
Returns an array of states you can `transition_to` from current state.

#### `Machine#can_transition_to?(:state)`
Returns true if the current state can transition to the passed state and all
applicable guards pass.

#### `Machine#transition_to!(:state)`
Transition to the passed state, returning `true` on success. Raises
`Statesmin::GuardFailedError` or `Statesmin::TransitionFailedError` on failure.

#### `Machine#transition_to(:state)`
Transition to the passed state, returning `true` on success. Swallows all
Statesmin exceptions and returns false on failure. (NB. if your guard or
callback code throws an exception, it will not be caught.)

## Frequently Asked Questions

#### Storing the state on the model object

If you wish to store the model state on the model directly, you can keep it up
to date using an `after_transition` hook:

```ruby
after_transition do |model, transition|
  model.state = transition.to_state
  model.save!
end
```

You could also use a calculated column or view in your database.

#### Accessing metadata from the last transition

Given a field `foo` that was stored in the metadata, you can access it like so:

```ruby
model_instance.last_transition.metadata["foo"]
```

#### Events

Used to using a state machine with "events"? Support for events is provided by
the [statesman-events](https://github.com/gocardless/statesman-events) gem. Once
that's included in your Gemfile you can include event functionality in your
state machine as follows:

```ruby
class OrderStateMachine
  include Statesmin::Machine
  include Statesmin::Events

  ...
end
```

## Testing Statesmin Implementations

This answer was abstracted from [this issue](https://github.com/gocardless/statesman/issues/77).

At GoCardless we focus on testing that:
- guards correctly prevent / allow transitions
- callbacks execute when expected and perform the expected actions

#### Testing Guards

Guards can be tested by asserting that `transition_to!` does or does not raise a `Statesmin::GuardFailedError`:

```ruby
describe "guards" do
  it "cannot transition from state foo to state bar" do
    expect { some_model.transition_to!(:bar) }.to raise_error(Statesmin::GuardFailedError)
  end

  it "can transition from state foo to state baz" do
    expect { some_model.transition_to!(:baz) }.to_not raise_error
  end
end
```

#### Testing Callbacks

Callbacks are tested by asserting that the action they perform occurs:

```ruby
describe "some callback" do
  it "adds one to the count property on the model" do
    expect { some_model.transition_to!(:some_state) }.
      to change { some_model.reload.count }.
      by(1)
  end
end
```

---

GoCardless ♥ open source. If you do too, come [join us](https://gocardless.com/jobs#software-engineer).
