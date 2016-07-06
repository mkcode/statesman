# Statesmin

[![Build Status](https://travis-ci.org/mkcode/statesmin.svg?branch=master)](https://travis-ci.org/mkcode/statesmin)

Statesmin is a fork of [stateman](https://github.com/gocardless/statesman) that
uses a machete to rip out all of the database related code leaving you with a
simple, robust, and well tested DSL for defining state machines in your
application.

### When to use statesmin rather than statesman:

 * You wish to manage an object's current state yourself, including not
   persisting it at all.
 * You have custom requirements for your transition log entries.
 * You need multiple (and very different) transition processes.
 * You enjoy and habitually write service objects with small scopes.
 * You will be frequently updating the state of an object and you can expect the
   transitions log to contain a lot of entries.

If any of the above apply to your application, then consider using statesmin. In
addition to defining your state machines, statesmin also requires you to:

 * Persist the current state of the object(s) yourself.
 * Instantiate a state machine with the object's current state yourself.
 * Maintain an transition / audit log yourself (if required)
 * Define a custom transition process yourself.

All in all, statesmin takes considerably more work to get setup and running than
statesman, so statesman is recommended if you need to get a state machine setup
and running without any special requirements or concerns.

### Working with Statesmin::Machine

Defining a state machine uses the same DSL as statesman. See
[tldr-usage](https://github.com/mkcode/statesmin#tldr-usage) for a more complete
example.

```ruby
class OrderStateMachine
  include Statesmin::Machine

  state :pending, initial: true
  state :checking_out
  state :purchased
  state :cancelled

  transition from: :pending,      to: [:checking_out, :cancelled]
  transition from: :checking_out, to: [:purchased, :cancelled]

  guard_transition(to: :checking_out) do |order|
    order.products_in_stock?
  end

  before_transition(from: :checking_out, to: :cancelled) do |order, transition|
    order.reallocate_stock
  end

  after_transition(to: :purchased) do |order, transition|
    MailerService.order_confirmation(order).deliver
  end
end
```

### Instantiating a Statesmin::Machine

The `Statesman::Machine` instance initializer now takes a `state` option which
sets the initial state of the state machine. If the `state` option is omitted,
the `initial: true` state from the Machine definition is used. Passing an
invalid state will yield a `Statesmin::InvalidStateError`.

```ruby
# A valid state is set as the current_state
state_machine = OrderStateMachine.new(Order.first, state: :cancelled)
state_machine.current_state # => "cancelled"

# Invalid states raise an InvaliedStateError
state_machine = OrderStateMachine.new(Order.first, state: :whoops)
# => raise Statesmin::InvalidStateError

# No state option sets the state to the initial state
state_machine = OrderStateMachine.new(Order.first)
state_machine.current_state # => "pending"
```

### Statesmin::Machine instance methods

All instance methods from statesman are available on statesmin with the
exception of `#history` and `#last_transition`. 

```ruby
state_machine = OrderStateMachine.new(Order.first)
state_machine.current_state # => "pending"
state_machine.in_state?(:failed, :cancelled) # => true/false
state_machine.allowed_transitions # => ["checking_out", "cancelled"]
state_machine.can_transition_to?(:cancelled) # => true/false
```

The `#transition_to` and `#transition_to!` methods are updated. They now simply
update the state machines internal current state to the new state when it is
valid. `transition_to!` raises a `Statesmin::TransitionFailedError` when an
invalid state is given. `transition_to` returns false.

```ruby
state_machine = OrderStateMachine.new(Order.first, state: :pending)
state_machine.current_state # => "pending"

state_machine.transition_to!(:invalid_state)
# => raise Statesmin::TransitionFailedError

state_machine.transition_to(:invalid_state)
# => false
state_machine.current_state # => "pending"

state_machine.transition_to!(:checking_out) # => true
state_machine.current_state # => "checking_out"
```

### Statesmin::Machine #transition_to! && #transition_to

The `#transition_to` and `#transition_to!` methods now both take a block
argument as well. If a block is given, any error raised in the block body will
halt the transition and not update the current state. `transition_to!` will
always raise the error from the block body, while `transition_to` will return
false if a `Statesmin::TransitionFailedError` is raised. `transition_to` will
still raise all other errors.

`#transition_to` and `#transition_to!` will both return the value returned from
the block when they are called without errors. The state machine's current state
is updated to the new state immediately after the block has executed.

Finally, `#transition_to` and `#transition_to!` will only execute the given
block if the state argument is a valid transition. Invalid state arguments will
behave the same way as they do without blocks, either returning false or raising
a `Statesmin::TransitionFailedError` respectively.

```ruby
state_machine = OrderStateMachine.new(Order.first, state: :pending)
state_machine.current_state # => "pending"

state_machine.transition_to! :invalid_state do
  puts 'never evaluated due to the :invalid_state argument'
end
# => raise Statesmin::TransitionFailedError

state_machine.transition_to :checking_out do
  raise Statesmin::TransitionFailedError
end
# => false

state_machine.transition_to :checking_out do
  raise Order::InvalidAddress
end
# => raise Order::InvalidAddress
state_machine.current_state # => "pending"

state_machine.transition_to :checking_out do
  OrderLogEntry.create!(order_data)
end
# => <#OrderLogEntry>
state_machine.current_state # => "checking_out
```

The transition block is the basis of how Statesmin allows for custom transition
behavior and distinguishes itself from Statesman. For small application or
transition requirements, the transition block may be sufficient but in most
cases defining a Transition class is recommended.

### Defining a Transition class

You are free to set up a state machine and corresponding transition behavior
however you like. The `TransitionHelper` module is included to help provide
structure and reduce boilerplate code.

Create a new class which includes the `Statesmin::TransitionHelper` module. This
module does the following for you:

 * Sets up a good outline for a Transaction (service) class
 * Delegates reader methods to an underlying state machine instance
 * Intercepts transition methods so they may be extend with specific behavior
 
`Statesmin::TransitionHelper` requires you to define two methods in your
transition class:

 * `state_machine` - This method returns the instance of the
   `Statesmin::Machine` class to use in the class. The reader methods delegate
   to this state machine instance. You will most likely also need it in other
   methods.

 * `transition` - This method defines the custom portion of the transition logic
   for this application and object. Usually, you will trigger state persistence,
   Transition logging, and callback execution from this method. Multiple
   database updates are always recommended to be wrapped in a transaction.

#### Example

The following example does the following during a transition:

 * Builds and saves an OrderLog record to the OrderLog table
 * Persists the current state of the order in the Order table.
 * Executes any before, after, and after_commit callbacks for the specific
   transition
 * Commits all of these database updates atomically (everything or nothing)
 * Returns the newly created order log record.

```ruby
class OrderTransitionService
  include Statesmin::TransitionHelper

  def initialize(order)
    @order = order
  end

  private

  def transition(next_state, data = {})
    order_log = build_order_log_entry(next_state, data)

    ::ActiveRecord::Base.transaction do
      state_machine.execute(:before, current_state, next_state, data)
      @order.update!(state: next_state)
      order_log.save!
      state_machine.execute(:after, current_state, next_state, data)
    end
    state_machine.execute(:after_commit, current_state, next_state, data)

    order_log
  end
  
  def state_machine
    @state_machine ||= OrderStateMachine.new(@order, state: @order.state)
  end
  
  def build_order_log_entry(next_state, data)
    log_attributes = { from: current_state, to: next_state, data: data }
    @order.order_logs.build(log_attributes)
  end
end
```

An instance of OrderTransitionService now has the same methods as
`Statesmin::Machine`.

```ruby
order_transition = OrderTransitionService.new(Order.first)

# reader methods are delegated to `state_machine`
order_transition.current_state # => "pending"
order_transition.in_state?(:failed, :cancelled) # => true/false
order_transition.allowed_transitions # => ["checking_out", "cancelled"]
order_transition.can_transition_to?(:cancelled) # => true/false

# `transition_to` and `transition_to!` also execute the transition method
order_transition.transition_to(:invalid_state)
# => false
order_transition.current_state # => "pending"

order_transition.transition_to!(:checking_out)
# => <#OrderLogEntry>
order_transition.current_state # => "checking_out"
```

### Flexibility

The above example defines behavior similar to Statesman. Some examples of what
else can be done with an open Transition class.

 * Have multiple state machines for the same object by adding a condition in the
   `states_machine` method.
 * Have multiple types a transitions for the same object by defining multiple
   Transition classes with the same instantiating object.
 * Have different Transition logs/tables for different objects.
 * Turn parts of a transition on and off based off of an initializer argument


The following is an adapted version of the original Statesman README.

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
