defmodule GroupStay.OperationFixture do
  def opening(id \\ "open", group \\ "group") do
    %{
      "operation_id" => id,
      "type" => "open_group",
      "group_id" => group,
      "guest_id" => "guest",
      "property_id" => "hotel",
      "occurred_on" => "2027-01-01",
      "arrival_on" => "2027-06-01",
      "departure_on" => "2027-06-03",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "a", "nightly_rate_cents" => 10000},
        %{"room_id" => "b", "nightly_rate_cents" => 5000}
      ]
    }
  end

  def operation(id, type, attrs \\ %{}) do
    Map.merge(
      %{
        "operation_id" => id,
        "type" => type,
        "group_id" => "group",
        "occurred_on" => "2027-05-02"
      },
      attrs
    )
  end
end
