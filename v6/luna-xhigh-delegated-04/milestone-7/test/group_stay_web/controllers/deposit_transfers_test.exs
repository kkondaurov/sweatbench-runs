defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.{CreditLot, Group, Repo}

  defp open_operation(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-02",
        "group_id" => group_id,
        "guest_id" => "guest-1",
        "property_id" => "ams-canal",
        "arrival_on" => "2027-04-01",
        "departure_on" => "2027-04-02",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "first", "nightly_rate_cents" => 100},
          %{"room_id" => "second", "nightly_rate_cents" => 200}
        ]
      },
      Map.put(overrides, "group_id", group_id)
    )
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{"operations" => operations})

  defp result(conn, operation),
    do: post_batch(conn, [operation]) |> json_response(200) |> Map.fetch!("results") |> hd()

  defp credit_lot(attrs \\ %{}) do
    Repo.insert!(
      struct(
        %CreditLot{
          guest_id: "guest-1",
          source_operation_id: "credit-source",
          remaining_cents: 20,
          expires_on: ~D[2027-06-01],
          cash_converted_cents: 0,
          issued_on: ~D[2027-01-01],
          unrecovered_clawback_cents: 0
        },
        attrs
      )
    )
  end

  test "moves mixed funding in reverse source order and preserves payment provenance", %{
    conn: conn
  } do
    post_batch(conn, [open_operation("source"), open_operation("destination")])
    credit_lot()

    assert result(conn, %{
             "operation_id" => "cash-1",
             "type" => "record_cash_payment",
             "occurred_on" => "2027-01-03",
             "group_id" => "source",
             "amount_cents" => 20
           })["revision"] == 2

    assert result(conn, %{
             "operation_id" => "credit-1",
             "type" => "apply_hotel_credit",
             "occurred_on" => "2027-01-03",
             "group_id" => "source",
             "amount_cents" => 20
           })["revision"] == 3

    assert result(conn, %{
             "operation_id" => "transfer-1",
             "type" => "transfer_deposit",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 30,
             "expected_revision" => 3,
             "destination_expected_revision" => 1
           }) == %{
             "operation_id" => "transfer-1",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 30,
             "source_outstanding_deposit_cents" => 50,
             "destination_outstanding_deposit_cents" => 30,
             "source_revision" => 4,
             "destination_revision" => 2
           }

    source = json_response(get(conn, "/api/v1/groups/source"), 200)["data"]
    destination = json_response(get(conn, "/api/v1/groups/destination"), 200)["data"]

    assert source["cash_paid_cents"] == 10
    assert source["credit_paid_cents"] == 0

    assert Enum.map(
             source["rooms"],
             &Map.take(&1, ["room_id", "cash_paid_cents", "credit_paid_cents"])
           ) == [
             %{"room_id" => "first", "cash_paid_cents" => 10, "credit_paid_cents" => 0},
             %{"room_id" => "second", "cash_paid_cents" => 0, "credit_paid_cents" => 0}
           ]

    assert destination["cash_paid_cents"] == 10
    assert destination["credit_paid_cents"] == 20

    assert Enum.map(
             destination["rooms"],
             &Map.take(&1, ["room_id", "cash_paid_cents", "credit_paid_cents"])
           ) == [
             %{"room_id" => "first", "cash_paid_cents" => 0, "credit_paid_cents" => 20},
             %{"room_id" => "second", "cash_paid_cents" => 10, "credit_paid_cents" => 0}
           ]

    assert json_response(get(conn, "/api/v1/payments/cash-1"), 200)["data"] == %{
             "payment_operation_id" => "cash-1",
             "original_group_id" => "source",
             "recorded_cents" => 20,
             "held_cents" => 20,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0,
             "held_by_group" => [
               %{"group_id" => "destination", "amount_cents" => 10},
               %{"group_id" => "source", "amount_cents" => 10}
             ]
           }

    for group_id <- ["source", "destination"] do
      group = Repo.get!(Group, group_id)
      Repo.update!(Ecto.Changeset.change(group, room_accounting_initialized: false))
    end

    assert {:ok, repaired_source} = GroupStay.get_group("source")
    assert {repaired_source["cash_paid_cents"], repaired_source["credit_paid_cents"]} == {10, 0}
    assert {:ok, repaired_destination} = GroupStay.get_group("destination")

    assert {repaired_destination["cash_paid_cents"], repaired_destination["credit_paid_cents"]} ==
             {10, 20}
  end

  test "checks both revisions before transfer validation and retries durably", %{conn: conn} do
    post_batch(conn, [open_operation("source"), open_operation("destination")])

    assert result(conn, %{
             "operation_id" => "cash-1",
             "type" => "record_cash_payment",
             "occurred_on" => "2027-01-03",
             "group_id" => "source",
             "amount_cents" => 10
           })["revision"] == 2

    stale_source = %{
      "operation_id" => "stale-source",
      "type" => "transfer_deposit",
      "source_group_id" => "source",
      "destination_group_id" => "destination",
      "amount_cents" => -1,
      "expected_revision" => 1,
      "destination_expected_revision" => 1
    }

    assert result(conn, stale_source) == %{
             "operation_id" => "stale-source",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "source",
             "expected_revision" => 1,
             "actual_revision" => 2
           }

    applied = %{
      "operation_id" => "transfer-1",
      "type" => "transfer_deposit",
      "source_group_id" => "source",
      "destination_group_id" => "destination",
      "amount_cents" => 5,
      "expected_revision" => 2,
      "destination_expected_revision" => 1
    }

    assert result(conn, applied)["source_revision"] == 3
    assert result(conn, applied)["destination_revision"] == 2
    assert result(conn, applied) == result(conn, applied)
    assert json_response(get(conn, "/api/v1/groups/source"), 200)["data"]["revision"] == 3
    assert json_response(get(conn, "/api/v1/groups/destination"), 200)["data"]["revision"] == 2
  end

  test "restores transferred credit at the destination without a second bonus", %{conn: conn} do
    post_batch(conn, [open_operation("source"), open_operation("destination")])
    credit_lot(%{source_operation_id: "original-credit", remaining_cents: 20})

    assert result(conn, %{
             "operation_id" => "credit-1",
             "type" => "apply_hotel_credit",
             "occurred_on" => "2027-01-03",
             "group_id" => "source",
             "amount_cents" => 20
           })["revision"] == 2

    assert result(conn, %{
             "operation_id" => "transfer-1",
             "type" => "transfer_deposit",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 20
           })["destination_revision"] == 2

    assert result(conn, %{
             "operation_id" => "cancel-1",
             "type" => "cancel_group",
             "occurred_on" => "2027-01-04",
             "group_id" => "destination"
           })["refunded_cents"] == 0

    assert json_response(get(conn, "/api/v1/guests/guest-1/credit?on=2027-01-04"), 200)["data"] ==
             %{
               "guest_id" => "guest-1",
               "available_cents" => 20,
               "lots" => [
                 %{
                   "source_operation_id" => "original-credit",
                   "remaining_cents" => 20,
                   "expires_on" => "2027-06-01"
                 }
               ]
             }
  end

  test "reductions and chargebacks revise groups holding transferred cash", %{conn: conn} do
    post_batch(conn, [open_operation("source"), open_operation("destination")])

    assert result(conn, %{
             "operation_id" => "cash-1",
             "type" => "record_cash_payment",
             "occurred_on" => "2027-01-03",
             "group_id" => "source",
             "amount_cents" => 20
           })["revision"] == 2

    assert result(conn, %{
             "operation_id" => "transfer-1",
             "type" => "transfer_deposit",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 10,
             "expected_revision" => 2,
             "destination_expected_revision" => 1
           }) == %{
             "operation_id" => "transfer-1",
             "status" => "applied",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 10,
             "source_outstanding_deposit_cents" => 50,
             "destination_outstanding_deposit_cents" => 50,
             "source_revision" => 3,
             "destination_revision" => 2
           }

    assert result(conn, %{
             "operation_id" => "reduce-1",
             "type" => "reduce_cash_payment",
             "payment_operation_id" => "cash-1",
             "amount_cents" => 5,
             "expected_revision" => 3
           })["revision"] == 4

    assert json_response(get(conn, "/api/v1/groups/destination"), 200)["data"]["revision"] == 3

    assert result(conn, %{
             "operation_id" => "chargeback-1",
             "type" => "charge_back_payment",
             "payment_operation_id" => "cash-1",
             "expected_revision" => 4
           })["revision"] == 5

    assert json_response(get(conn, "/api/v1/groups/source"), 200)["data"]["revision"] == 5
    assert json_response(get(conn, "/api/v1/groups/destination"), 200)["data"]["revision"] == 4

    assert json_response(get(conn, "/api/v1/payments/cash-1"), 200)["data"] == %{
             "payment_operation_id" => "cash-1",
             "original_group_id" => "source",
             "recorded_cents" => 20,
             "held_cents" => 0,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 5,
             "charged_back_cents" => 15,
             "held_by_group" => []
           }
  end

  test "reports transfer validation errors with the addressed group", %{conn: conn} do
    post_batch(conn, [
      open_operation("source"),
      open_operation("destination", %{"guest_id" => "guest-2"}),
      open_operation("small", %{"rooms" => [%{"room_id" => "only", "nightly_rate_cents" => 20}]})
    ])

    assert result(conn, %{
             "operation_id" => "missing-source",
             "type" => "transfer_deposit",
             "source_group_id" => "missing",
             "destination_group_id" => "destination",
             "amount_cents" => 1
           }) == %{
             "operation_id" => "missing-source",
             "status" => "rejected",
             "code" => "group_not_found",
             "group_id" => "missing"
           }

    assert result(conn, %{
             "operation_id" => "wrong-guest",
             "type" => "transfer_deposit",
             "source_group_id" => "source",
             "destination_group_id" => "destination",
             "amount_cents" => 1
           })["code"] == "invalid_transfer"

    assert result(conn, %{
             "operation_id" => "invalid-amount",
             "type" => "transfer_deposit",
             "source_group_id" => "source",
             "destination_group_id" => "small",
             "amount_cents" => 0
           })["code"] == "invalid_amount"

    assert result(conn, %{
             "operation_id" => "cash-1",
             "type" => "record_cash_payment",
             "occurred_on" => "2027-01-03",
             "group_id" => "source",
             "amount_cents" => 5
           })["revision"] == 2

    assert result(conn, %{
             "operation_id" => "too-much-source",
             "type" => "transfer_deposit",
             "source_group_id" => "source",
             "destination_group_id" => "small",
             "amount_cents" => 6,
             "expected_revision" => 2,
             "destination_expected_revision" => 1
           })["code"] == "transfer_exceeds_held_funding"

    assert result(conn, %{
             "operation_id" => "too-much-destination",
             "type" => "transfer_deposit",
             "source_group_id" => "source",
             "destination_group_id" => "small",
             "amount_cents" => 5,
             "expected_revision" => 2,
             "destination_expected_revision" => 1
           })["code"] == "transfer_exceeds_outstanding"

    assert result(conn, %{
             "operation_id" => "move-small",
             "type" => "reschedule_group",
             "occurred_on" => "2027-01-03",
             "group_id" => "small",
             "new_arrival_on" => "2027-04-02"
           })["revision"] == 2

    assert result(conn, %{
             "operation_id" => "stale-destination",
             "type" => "transfer_deposit",
             "source_group_id" => "source",
             "destination_group_id" => "small",
             "amount_cents" => -1,
             "expected_revision" => 2,
             "destination_expected_revision" => 1
           }) == %{
             "operation_id" => "stale-destination",
             "status" => "rejected",
             "code" => "stale_revision",
             "group_id" => "small",
             "expected_revision" => 1,
             "actual_revision" => 2
           }
  end
end
