defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  import Ecto.Query

  alias GroupStay.Groups.CashAllocation
  alias GroupStay.Groups.CreditLotEntitlement
  alias GroupStay.Groups.HotelCreditAllocation
  alias GroupStay.Groups.HotelCreditLot
  alias GroupStay.Repo

  defp json_post(conn, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(body))
  end

  defp open_operation(group_id, operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-11",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "#{group_id}-a", "nightly_rate_cents" => 500},
          %{"room_id" => "#{group_id}-b", "nightly_rate_cents" => 500}
        ]
      },
      overrides
    )
  end

  defp transfer_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => "transfer-1",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-06",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-82",
        "amount_cents" => 1
      },
      overrides
    )
  end

  test "moves held cash across groups, preserves batch visibility, and is idempotent", %{
    conn: conn
  } do
    operations = [
      open_operation("group-81", "open-source"),
      open_operation("group-82", "open-destination"),
      %{
        "operation_id" => "pay-1",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 150
      },
      transfer_operation(%{"amount_cents" => 120})
    ]

    assert %{"results" => [_, _, payment, transfer]} =
             json_post(conn, %{"operations" => operations}) |> json_response(200)

    assert payment["revision"] == 2

    assert transfer == %{
             "operation_id" => "transfer-1",
             "status" => "applied",
             "source_group_id" => "group-81",
             "destination_group_id" => "group-82",
             "amount_cents" => 120,
             "source_outstanding_deposit_cents" => 170,
             "destination_outstanding_deposit_cents" => 80,
             "source_revision" => 3,
             "destination_revision" => 2
           }

    assert %{"results" => [retry]} =
             json_post(conn, %{"operations" => [transfer_operation(%{"amount_cents" => 120})]})
             |> json_response(200)

    assert retry == transfer

    assert %{"data" => source} =
             get(build_conn(), "/api/v1/groups/group-81") |> json_response(200)

    assert source["cash_paid_cents"] == 30

    assert Enum.map(source["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) ==
             [{"group-81-a", 30}, {"group-81-b", 0}]

    assert %{"data" => destination} =
             get(build_conn(), "/api/v1/groups/group-82") |> json_response(200)

    assert Enum.map(destination["rooms"], &{&1["room_id"], &1["cash_paid_cents"]}) ==
             [{"group-82-a", 100}, {"group-82-b", 20}]

    assert %{"data" => statement} =
             get(build_conn(), "/api/v1/payments/pay-1") |> json_response(200)

    assert statement["held_by_group"] == [
             %{"group_id" => "group-81", "amount_cents" => 30},
             %{"group_id" => "group-82", "amount_cents" => 120}
           ]

    assert %{"data" => ledger} =
             get(build_conn(), "/api/v1/ledger?on=2026-10-06") |> json_response(200)

    assert ledger["cash_held_cents"] == 150
    assert ledger["cash_refunded_cents"] == 0
    assert ledger["cash_retained_cents"] == 0
    assert ledger["cash_converted_to_credit_cents"] == 0
  end

  test "moves mixed funding without changing credit liability and settles at destination", %{
    conn: conn
  } do
    operations = [
      open_operation("donor", "open-donor", %{
        "rooms" => [%{"room_id" => "donor-room", "nightly_rate_cents" => 500}]
      }),
      %{
        "operation_id" => "donor-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "donor",
        "amount_cents" => 100
      },
      %{
        "operation_id" => "donor-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-10-05",
        "group_id" => "donor",
        "refund_method" => "hotel_credit"
      },
      open_operation("group-81", "open-source", %{
        "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 500}]
      }),
      %{
        "operation_id" => "source-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 50
      },
      %{
        "operation_id" => "source-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 50
      },
      open_operation("group-82", "open-destination", %{
        "rooms" => [%{"room_id" => "destination-room", "nightly_rate_cents" => 500}]
      }),
      transfer_operation(%{"amount_cents" => 100})
    ]

    assert %{"results" => [_, _, donor_cancel, _, _, _, _, transfer]} =
             json_post(conn, %{"operations" => operations}) |> json_response(200)

    assert donor_cancel["credit_issued_cents"] == 110
    assert transfer["source_outstanding_deposit_cents"] == 100
    assert transfer["destination_outstanding_deposit_cents"] == 0

    assert Repo.all(
             from allocation in CashAllocation,
               where: allocation.group_id == "group-82",
               select: {allocation.payment_operation_id, allocation.amount_cents}
           ) == [{"source-pay", 50}]

    assert Repo.all(
             from allocation in HotelCreditAllocation,
               where: allocation.group_id == "group-82",
               select: {allocation.operation_id, allocation.amount_cents}
           ) == [{"source-credit", 50}]

    assert %{"data" => ledger} =
             get(build_conn(), "/api/v1/ledger?on=2026-10-06") |> json_response(200)

    assert ledger["cash_held_cents"] == 50
    assert ledger["cash_converted_to_credit_cents"] == 100
    assert ledger["credit_liability_cents"] == 110

    assert %{"results" => [cancellation]} =
             json_post(conn, %{
               "operations" => [
                 %{
                   "operation_id" => "destination-cancel",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-10-06",
                   "group_id" => "group-82"
                 }
               ]
             })
             |> json_response(200)

    assert cancellation["refunded_cents"] == 50
    assert cancellation["retained_cents"] == 0

    assert get(build_conn(), "/api/v1/guests/guest-22/credit?on=2026-10-06")
           |> json_response(200) == %{
             "data" => %{
               "guest_id" => "guest-22",
               "available_cents" => 110,
               "lots" => [
                 %{
                   "source_operation_id" => "donor-cancel",
                   "remaining_cents" => 110,
                   "expires_on" => "2027-10-06"
                 }
               ]
             }
           }
  end

  test "reductions and chargebacks follow a payment across groups", %{conn: conn} do
    assert %{"results" => [_, _, _, transfer]} =
             json_post(conn, %{
               "operations" => [
                 open_operation("group-81", "open-source", %{
                   "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 500}]
                 }),
                 open_operation("group-82", "open-destination", %{
                   "rooms" => [%{"room_id" => "destination-room", "nightly_rate_cents" => 500}]
                 }),
                 %{
                   "operation_id" => "pay-1",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-81",
                   "amount_cents" => 100
                 },
                 transfer_operation(%{"amount_cents" => 50})
               ]
             })
             |> json_response(200)

    assert transfer["source_revision"] == 3
    assert transfer["destination_revision"] == 2

    assert %{"results" => [reduction]} =
             json_post(conn, %{
               "operations" => [
                 %{
                   "operation_id" => "reduce-1",
                   "type" => "reduce_cash_payment",
                   "occurred_on" => "2026-10-07",
                   "payment_operation_id" => "pay-1",
                   "amount_cents" => 60,
                   "expected_revision" => 3
                 }
               ]
             })
             |> json_response(200)

    assert reduction == %{
             "operation_id" => "reduce-1",
             "status" => "applied",
             "payment_operation_id" => "pay-1",
             "group_id" => "group-81",
             "amount_cents" => 60,
             "outstanding_deposit_cents" => 60,
             "revision" => 4
           }

    assert %{"data" => destination} =
             get(build_conn(), "/api/v1/groups/group-82") |> json_response(200)

    assert destination["revision"] == 3
    assert destination["outstanding_deposit_cents"] == 100

    assert %{"results" => [chargeback]} =
             json_post(conn, %{
               "operations" => [
                 %{
                   "operation_id" => "chargeback-1",
                   "type" => "charge_back_payment",
                   "occurred_on" => "2026-10-08",
                   "payment_operation_id" => "pay-1",
                   "expected_revision" => 4
                 }
               ]
             })
             |> json_response(200)

    assert chargeback["charged_back_cents"] == 40
    assert chargeback["outstanding_deposit_cents"] == 100
    assert chargeback["revision"] == 5

    assert %{"data" => statement} =
             get(build_conn(), "/api/v1/payments/pay-1") |> json_response(200)

    assert statement["held_cents"] == 0
    assert statement["reduced_cents"] == 60
    assert statement["charged_back_cents"] == 40
    assert statement["held_by_group"] == []

    assert %{"data" => destination} =
             get(build_conn(), "/api/v1/groups/group-82") |> json_response(200)

    assert destination["revision"] == 3
    assert destination["outstanding_deposit_cents"] == 100
  end

  test "destination credit entitlements follow transfer allocation order", %{conn: conn} do
    assert %{"results" => [_, _, _, _, _, _]} =
             json_post(conn, %{
               "operations" => [
                 open_operation("group-81", "open-source", %{
                   "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 500}]
                 }),
                 open_operation("group-82", "open-destination", %{
                   "rooms" => [%{"room_id" => "destination-room", "nightly_rate_cents" => 1_000}]
                 }),
                 %{
                   "operation_id" => "payment-a",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-04",
                   "group_id" => "group-81",
                   "amount_cents" => 51
                 },
                 %{
                   "operation_id" => "payment-b",
                   "type" => "record_cash_payment",
                   "occurred_on" => "2026-10-05",
                   "group_id" => "group-81",
                   "amount_cents" => 49
                 },
                 transfer_operation(%{"operation_id" => "transfer-b", "amount_cents" => 49}),
                 transfer_operation(%{"operation_id" => "transfer-a", "amount_cents" => 51})
               ]
             })
             |> json_response(200)

    assert %{"results" => [cancellation]} =
             json_post(conn, %{
               "operations" => [
                 %{
                   "operation_id" => "cancel-destination",
                   "type" => "cancel_group",
                   "occurred_on" => "2026-10-06",
                   "group_id" => "group-82",
                   "refund_method" => "hotel_credit"
                 }
               ]
             })
             |> json_response(200)

    assert cancellation["credit_issued_cents"] == 110

    lot = Repo.get_by!(HotelCreditLot, source_operation_id: "cancel-destination")

    assert Repo.all(
             from entitlement in CreditLotEntitlement,
               where: entitlement.lot_id == ^lot.id,
               order_by: [asc: entitlement.id],
               select: {entitlement.payment_operation_id, entitlement.amount_cents}
           ) == [{"payment-b", 54}, {"payment-a", 56}]
  end

  test "checks both revision guards before transfer validation", %{conn: conn} do
    assert json_post(conn, %{
             "operations" => [
               open_operation("group-81", "open-source", %{
                 "rooms" => [%{"room_id" => "source-room", "nightly_rate_cents" => 500}]
               }),
               open_operation("group-82", "open-destination", %{
                 "rooms" => [%{"room_id" => "destination-room", "nightly_rate_cents" => 500}]
               })
             ]
           })
           |> json_response(200)

    assert %{"results" => [source_stale, destination_stale]} =
             json_post(conn, %{
               "operations" => [
                 transfer_operation(%{
                   "operation_id" => "source-stale",
                   "expected_revision" => 0,
                   "amount_cents" => -1
                 }),
                 transfer_operation(%{
                   "operation_id" => "destination-stale",
                   "destination_expected_revision" => 0,
                   "amount_cents" => -1
                 })
               ]
             })
             |> json_response(200)

    assert source_stale["code"] == "stale_revision"
    assert source_stale["group_id"] == "group-81"
    assert source_stale["expected_revision"] == 0
    assert source_stale["actual_revision"] == 1

    assert destination_stale["code"] == "stale_revision"
    assert destination_stale["group_id"] == "group-82"
    assert destination_stale["expected_revision"] == 0
    assert destination_stale["actual_revision"] == 1
  end
end
