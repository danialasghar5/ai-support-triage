require "test_helper"

class TicketTest < ActiveSupport::TestCase
  test "should be valid with valid attributes" do
    ticket = Ticket.new(customer_email: "user@example.com", body: "Help, my app is down!")
    assert ticket.valid?
    assert_equal "pending", ticket.status
    assert_equal({}, ticket.metadata)
  end

  test "should be invalid without customer_email" do
    ticket = Ticket.new(body: "Help, my app is down!")
    assert_not ticket.valid?
    assert_includes ticket.errors[:customer_email], "can't be blank"
  end

  test "should be invalid with incorrect email format" do
    ticket = Ticket.new(customer_email: "not-an-email", body: "Help, my app is down!")
    assert_not ticket.valid?
    assert_includes ticket.errors[:customer_email], "is invalid"
  end

  test "should be invalid without body" do
    ticket = Ticket.new(customer_email: "user@example.com")
    assert_not ticket.valid?
    assert_includes ticket.errors[:body], "can't be blank"
  end

  test "should support status transitions using enum helper methods" do
    ticket = Ticket.create!(customer_email: "user@example.com", body: "Help, my app is down!")
    assert ticket.pending?

    ticket.processing!
    assert ticket.processing?

    ticket.completed!
    assert ticket.completed?

    ticket.failed!
    assert ticket.failed?
  end
end

