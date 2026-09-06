defmodule GroupStayWeb.PolicyVersionTest do
  use GroupStayWeb.ConnCase

  defp open_op(overrides) do
    Map.merge(
      valid_open_operation(),
      Map.merge(%{"operation_id" => "op-open-#{overrides["group_id"]}"}, overrides)
    )
  end

  describe "policy_version and refundable_until in group reads" do
    test "flexible groups booked before 2027-01-01 keep the 14-day window", %{conn: conn} do
      open_group_fixture(conn, %{"occurred_on" => "2026-12-31"})

      data = group_data(conn, "group-81")
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2026-11-26"
    end

    test "flexible groups booked on 2027-01-01 use the 30-day window", %{conn: conn} do
      open_group_fixture(conn, %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-18"
      })

      data = group_data(conn, "group-81")
      assert data["policy_version"] == "flex-30"
      assert data["refundable_until"] == "2027-02-13"
    end

    test "flexible groups booked after 2027-01-01 use the 30-day window", %{conn: conn} do
      open_group_fixture(conn, %{
        "occurred_on" => "2027-02-01",
        "arrival_on" => "2027-06-10",
        "departure_on" => "2027-06-13"
      })

      data = group_data(conn, "group-81")
      assert data["policy_version"] == "flex-30"
      assert data["refundable_until"] == "2027-05-11"
    end

    test "advance purchase groups are never refundable", %{conn: conn} do
      open_group_fixture(conn, %{"rate_plan" => "advance_purchase"})

      data = group_data(conn, "group-81")
      assert data["policy_version"] == "advance-nonrefundable"
      assert data["refundable_until"] == nil
    end
  end

  describe "cancellation windows" do
    test "a flex-30 group cancelled exactly 30 days before arrival is refundable", %{conn: conn} do
      open_group_fixture(conn, %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-18"
      })

      pay_group(conn, "group-81", 5000)
      result = cancel_group(conn, "group-81", "2027-02-13")

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 5000
      assert result["retained_cents"] == 0
    end

    test "a flex-30 group cancelled 29 days before arrival is non-refundable", %{conn: conn} do
      open_group_fixture(conn, %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-18"
      })

      pay_group(conn, "group-81", 5000)
      result = cancel_group(conn, "group-81", "2027-02-14")

      assert result["status"] == "applied"
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5000
    end

    test "a flex-14 group cancelled 15 days before arrival is still refundable", %{conn: conn} do
      open_group_fixture(conn)
      pay_group(conn, "group-81", 5000)
      result = cancel_group(conn, "group-81", "2026-11-25")

      assert result["refunded_cents"] == 5000
      assert result["retained_cents"] == 0
    end
  end

  describe "rescheduling" do
    test "keeps the fixed policy version and recomputes refundable_until", %{conn: conn} do
      open_group_fixture(conn, %{"occurred_on" => "2026-12-01"})

      %{"results" => [result]} =
        submit_batch(conn, [
          %{
            "operation_id" => "op-3001",
            "type" => "reschedule_group",
            "occurred_on" => "2026-12-05",
            "group_id" => "group-81",
            "new_arrival_on" => "2027-06-01"
          }
        ])

      assert result["policy_version"] == "flex-14"
      assert result["refundable_until"] == "2027-05-18"

      data = group_data(conn, "group-81")
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-05-18"
    end

    test "reports the 30-day policy for a flex-30 group", %{conn: conn} do
      open_group_fixture(conn, %{
        "occurred_on" => "2027-01-01",
        "arrival_on" => "2027-03-15",
        "departure_on" => "2027-03-18"
      })

      %{"results" => [result]} =
        submit_batch(conn, [
          %{
            "operation_id" => "op-3001",
            "type" => "reschedule_group",
            "occurred_on" => "2027-01-05",
            "group_id" => "group-81",
            "new_arrival_on" => "2027-04-10"
          }
        ])

      assert result["policy_version"] == "flex-30"
      assert result["refundable_until"] == "2027-03-11"
    end

    test "reports a null refundable_until for advance purchase groups", %{conn: conn} do
      open_group_fixture(conn, %{"rate_plan" => "advance_purchase"})

      %{"results" => [result]} =
        submit_batch(conn, [
          %{
            "operation_id" => "op-3001",
            "type" => "reschedule_group",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-81",
            "new_arrival_on" => "2026-12-20"
          }
        ])

      assert result["policy_version"] == "advance-nonrefundable"
      assert result["refundable_until"] == nil
    end
  end

  describe "policy fixed at open time" do
    test "a group booked before the cutoff keeps flex-14 even with a later arrival", %{conn: conn} do
      submit_batch(conn, [
        open_op(%{
          "group_id" => "group-81",
          "occurred_on" => "2026-12-31",
          "arrival_on" => "2027-06-10",
          "departure_on" => "2027-06-13"
        })
      ])

      data = group_data(conn, "group-81")
      assert data["policy_version"] == "flex-14"
      assert data["refundable_until"] == "2027-05-27"
    end
  end
end
