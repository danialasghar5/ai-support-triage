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

  test "should accept every urgency in the known vocabulary" do
    Ticket::URGENCIES.each do |urgency|
      ticket = Ticket.new(customer_email: "user@example.com", body: "help", urgency: urgency)
      assert ticket.valid?, "expected urgency #{urgency.inspect} to be valid"
    end
  end

  test "should reject an urgency outside the known vocabulary" do
    ticket = Ticket.new(customer_email: "user@example.com", body: "help", urgency: "catastrophic")
    assert_not ticket.valid?
    assert_includes ticket.errors[:urgency], "is not included in the list"
  end

  test "should reject an absurdly long category" do
    ticket = Ticket.new(customer_email: "user@example.com", body: "help", category: "x" * 51)
    assert_not ticket.valid?
    assert_includes ticket.errors[:category], "is too long (maximum is 50 characters)"
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
