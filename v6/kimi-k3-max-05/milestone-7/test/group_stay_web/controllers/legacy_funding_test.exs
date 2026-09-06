defmodule GroupStayWeb.LegacyFundingTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Groups.CashAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  defp post_batch(conn, body) do
    post(conn, ~p"/api/v1/partner-batches", body)
  end

  defp get_group(group_id) do
    conn = get(build_conn(), ~p"/api/v1/groups/#{group_id}")
    json_response(conn, 200)["data"]
  end

  defp get_ledger(query \\ "") do
    conn = get(build_conn(), "/api/v1/ledger" <> query)
    json_response(conn, 200)["data"]
  end

  defp get_credit(guest_id, query \\ "") do
    conn = get(build_conn(), "/api/v1/guests/#{guest_id}/credit" <> query)
    json_response(conn, 200)["data"]
  end

  # Seeds a group as the room-accounting migration would have left it: rooms
  # with their amounts, and 1_000 of legacy cash (no durable operation
  # identity) held on room-a.
  defp seed_legacy_group do
    {:ok, group} =
      %Group{}
      |> Ecto.Changeset.change(
        group_id: "group-legacy",
        guest_id: "guest-22",
        property_id: "ams-canal",
        rate_plan: "flexible",
        status: "active",
        revision: 1,
        booked_on: ~D[2026-10-03],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-13],
        policy_version: "flex-14",
        lodging_total_cents: 97_500,
        deposit_due_cents: 19_500,
        deposit_paid_cents: 1_000,
        cash_paid_cents: 1_000
      )
      |> Repo.insert()

    {:ok, room_a} =
      %Room{}
      |> Ecto.Changeset.change(
        group_id: group.id,
        position: 0,
        room_id: "room-a",
        nightly_rate_cents: 15_000,
        status: "active",
        lodging_total_cents: 45_000,
        deposit_due_cents: 9_000,
        cash_paid_cents: 1_000
      )
      |> Repo.insert()

    {:ok, _room_b} =
      %Room{}
      |> Ecto.Changeset.change(
        group_id: group.id,
        position: 1,
        room_id: "room-b",
        nightly_rate_cents: 17_500,
        status: "active",
        lodging_total_cents: 52_500,
        deposit_due_cents: 10_500
      )
      |> Repo.insert()

    {:ok, _allocation} =
      %CashAllocation{}
      |> Ecto.Changeset.change(
        group_id: group.id,
        room_id: room_a.id,
        payment_operation_id: nil,
        amount_cents: 1_000,
        status: "held"
      )
      |> Repo.insert()

    group
  end

  test "legacy funding has no durable identity and cannot be targeted", %{conn: conn} do
    seed_legacy_group()

    conn =
      post_batch(conn, %{
        "operations" => [
          %{
            "operation_id" => "op-reduce",
            "type" => "reduce_cash_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "legacy-block",
            "amount_cents" => 100
          },
          %{
            "operation_id" => "op-chargeback",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-10-05",
            "payment_operation_id" => "legacy-block"
          }
        ]
      })

    assert %{"results" => [reduce, chargeback]} = json_response(conn, 200)
    assert reduce["code"] == "operation_not_found"
    assert chargeback["code"] == "operation_not_found"

    # the legacy cash is untouched
    assert %{"cash_held_cents" => 1_000} = get_ledger()
  end

  test "the senior block takes the first entitlement in a converted lot", %{conn: conn} do
    seed_legacy_group()

    operations = [
      %{
        "operation_id" => "op-pay-new",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-legacy",
        "amount_cents" => 500
      },
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-20",
        "group_id" => "group-legacy",
        "refund_method" => "hotel_credit"
      }
    ]

    conn = post_batch(conn, %{"operations" => operations})

    assert %{"results" => [payment, cancel]} = json_response(conn, 200)
    assert payment["status"] == "applied"
    # the durable payment lands after the senior block on room-a
    assert payment["outstanding_deposit_cents"] == 18_000
    # 1_500 converted with the bonus computed once
    assert cancel["credit_issued_cents"] == 1_650

    group = get_group("group-legacy")
    assert group["status"] == "cancelled"

    # entitlements: the senior block earns credit_value(1_000) = 1_100; the
    # durable payment earns credit_value(1_500) - credit_value(1_000) = 550.
    # Charging back the durable payment revokes only its own entitlement.
    conn =
      post_batch(build_conn(), %{
        "operations" => [
          %{
            "operation_id" => "op-chargeback",
            "type" => "charge_back_payment",
            "occurred_on" => "2026-11-21",
            "payment_operation_id" => "op-pay-new"
          }
        ]
      })

    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "applied"
    assert result["charged_back_cents"] == 500

    # the senior block's 1_100 entitlement is untouched
    assert %{"credit_liability_cents" => 1_100} = get_ledger()
    assert get_credit("guest-22")["available_cents"] == 1_100

    conn = get(build_conn(), ~p"/api/v1/payments/op-pay-new")

    assert %{
             "data" => %{
               "recorded_cents" => 500,
               "converted_to_credit_cents" => 0,
               "charged_back_cents" => 500
             }
           } = json_response(conn, 200)
  end
end
