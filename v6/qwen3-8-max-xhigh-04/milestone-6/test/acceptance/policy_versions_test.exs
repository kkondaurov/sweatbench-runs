defmodule GroupStayWeb.Acceptance.PolicyVersionsTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Funding
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  defp submit(conn, operations) do
    conn
    |> post("/api/v1/partner-batches", %{"operations" => operations})
    |> json_response(200)
    |> Map.fetch!("results")
  end

  defp open_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-open",
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => "group-81",
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10000}]
      },
      overrides
    )
  end

  defp group(conn, group_id) do
    conn
    |> get("/api/v1/groups/#{group_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  describe "policy versions" do
    test "flexible groups booked before 2027-01-01 keep the 14-day window" do
      submit(build_conn(), [open_op()])

      group = group(build_conn(), "group-81")
      assert group["policy_version"] == "flex-14"
      assert group["refundable_until"] == "2026-11-26"
    end

    test "flexible groups booked on 2027-01-01 use the 30-day window" do
      submit(build_conn(), [
        open_op(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-04-10",
          "departure_on" => "2027-04-12"
        })
      ])

      group = group(build_conn(), "group-81")
      assert group["policy_version"] == "flex-30"
      assert group["refundable_until"] == "2027-03-11"
    end

    test "a flex-30 cancellation exactly 30 days before arrival is refundable" do
      submit(build_conn(), [
        open_op(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-04-10",
          "departure_on" => "2027-04-12"
        }),
        %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2027-01-02",
          "group_id" => "group-81",
          "amount_cents" => 4000
        }
      ])

      assert [%{"status" => "applied", "refunded_cents" => 4000, "retained_cents" => 0}] =
               submit(build_conn(), [
                 %{
                   "operation_id" => "op-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-03-11",
                   "group_id" => "group-81"
                 }
               ])
    end

    test "a flex-30 cancellation 29 days before arrival is non-refundable" do
      submit(build_conn(), [
        open_op(%{
          "occurred_on" => "2027-01-01",
          "arrival_on" => "2027-04-10",
          "departure_on" => "2027-04-12"
        }),
        %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2027-01-02",
          "group_id" => "group-81",
          "amount_cents" => 4000
        }
      ])

      assert [%{"status" => "applied", "refunded_cents" => 0, "retained_cents" => 4000}] =
               submit(build_conn(), [
                 %{
                   "operation_id" => "op-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-03-12",
                   "group_id" => "group-81"
                 }
               ])
    end

    test "advance-purchase groups are advance-nonrefundable without a refundable_until" do
      submit(build_conn(), [open_op(%{"rate_plan" => "advance_purchase"})])

      group = group(build_conn(), "group-81")
      assert group["policy_version"] == "advance-nonrefundable"
      assert group["refundable_until"] == nil
    end

    test "rescheduling never moves a group to a newer policy" do
      submit(build_conn(), [open_op()])

      assert [
               %{
                 "operation_id" => "op-move",
                 "status" => "applied",
                 "group_id" => "group-81",
                 "new_arrival_on" => "2027-06-20",
                 "new_departure_on" => "2027-06-23",
                 "policy_version" => "flex-14",
                 "refundable_until" => "2027-06-06",
                 "revision" => 2
               }
             ] =
               submit(build_conn(), [
                 %{
                   "operation_id" => "op-move",
                   "type" => "reschedule_group",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-81",
                   "new_arrival_on" => "2027-06-20"
                 }
               ])

      submit(build_conn(), [
        %{
          "operation_id" => "op-pay",
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-05",
          "group_id" => "group-81",
          "amount_cents" => 5000
        }
      ])

      # 20 days before arrival is refundable under the fixed flex-14 policy,
      # but would not be under flex-30.
      assert [%{"status" => "applied", "refunded_cents" => 5000, "retained_cents" => 0}] =
               submit(build_conn(), [
                 %{
                   "operation_id" => "op-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2027-05-31",
                   "group_id" => "group-81"
                 }
               ])
    end
  end

  describe "pre-release groups" do
    defp insert_legacy_group(attrs) do
      Repo.insert!(
        struct!(Group, %{
          guest_id: "guest-22",
          property_id: "ams-canal",
          status: "active",
          revision: 1,
          deposit_paid_cents: 0,
          rooms: [%GroupStay.Groups.Room{room_id: "room-a", nightly_rate_cents: 10000}],
          policy_version: nil
        })
        |> Map.merge(attrs)
      )
    end

    test "remain readable and receive the policy their original booking date implies" do
      insert_legacy_group(%{
        group_id: "legacy-flex-14",
        rate_plan: "flexible",
        booked_on: ~D[2026-05-01],
        arrival_on: ~D[2026-08-01],
        departure_on: ~D[2026-08-03],
        lodging_total_cents: 20000,
        deposit_due_cents: 4000
      })

      insert_legacy_group(%{
        group_id: "legacy-flex-30",
        rate_plan: "flexible",
        booked_on: ~D[2027-03-15],
        arrival_on: ~D[2027-06-30],
        departure_on: ~D[2027-07-02],
        lodging_total_cents: 20000,
        deposit_due_cents: 4000
      })

      insert_legacy_group(%{
        group_id: "legacy-advance",
        rate_plan: "advance_purchase",
        booked_on: ~D[2026-05-01],
        arrival_on: ~D[2026-08-01],
        departure_on: ~D[2026-08-03],
        lodging_total_cents: 20000,
        deposit_due_cents: 20000
      })

      Groups.backfill_policy_versions()

      flex_14 = group(build_conn(), "legacy-flex-14")
      assert flex_14["policy_version"] == "flex-14"
      assert flex_14["refundable_until"] == "2026-07-18"

      flex_30 = group(build_conn(), "legacy-flex-30")
      assert flex_30["policy_version"] == "flex-30"
      assert flex_30["refundable_until"] == "2027-05-31"

      advance = group(build_conn(), "legacy-advance")
      assert advance["policy_version"] == "advance-nonrefundable"
      assert advance["refundable_until"] == nil
    end

    test "backfilled groups keep their original cancellation window" do
      insert_legacy_group(%{
        group_id: "legacy-flex-14",
        rate_plan: "flexible",
        booked_on: ~D[2026-05-01],
        arrival_on: ~D[2026-08-01],
        departure_on: ~D[2026-08-03],
        lodging_total_cents: 20000,
        deposit_due_cents: 4000
      })

      Groups.backfill_policy_versions()
      Funding.backfill_room_accounting()

      assert [%{"status" => "applied", "revision" => 2}] =
               submit(build_conn(), [
                 %{
                   "operation_id" => "op-pay",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-05-02",
                   "group_id" => "legacy-flex-14",
                   "amount_cents" => 2000
                 }
               ])

      assert [%{"status" => "applied", "refunded_cents" => 2000, "retained_cents" => 0}] =
               submit(build_conn(), [
                 %{
                   "operation_id" => "op-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-07-18",
                   "group_id" => "legacy-flex-14"
                 }
               ])
    end
  end
end
