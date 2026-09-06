defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.{PaymentDisposition, Repo}

  defp open_operation(group_id, operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-transfer",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 10_000}]
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{"operations" => operations}))
  end

  test "moves held cash in a visible batch and exposes its current groups", %{conn: conn} do
    assert %{
             "results" => [
               %{"revision" => 1},
               %{"revision" => 1},
               %{"revision" => 2},
               %{
                 "status" => "applied",
                 "amount_cents" => 3_000,
                 "source_revision" => 3,
                 "destination_revision" => 2,
                 "source_outstanding_deposit_cents" => 4_000,
                 "destination_outstanding_deposit_cents" => 9_000
               }
             ]
           } =
             post_batch(conn, [
               open_operation("source", "source-open"),
               open_operation("destination", "destination-open", %{
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
                 ]
               }),
               %{
                 "operation_id" => "source-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "source",
                 "amount_cents" => 5_000,
                 "expected_revision" => 1
               },
               %{
                 "operation_id" => "transfer-1",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2026-10-05",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 3_000,
                 "expected_revision" => 2,
                 "destination_expected_revision" => 1
               }
             ])
             |> json_response(200)

    source = json_response(get(conn, "/api/v1/groups/source"), 200)["data"]
    destination = json_response(get(conn, "/api/v1/groups/destination"), 200)["data"]

    assert source["revision"] == 3
    assert source["cash_paid_cents"] == 2_000
    assert source["outstanding_deposit_cents"] == 4_000
    assert destination["revision"] == 2
    assert destination["cash_paid_cents"] == 3_000
    assert Enum.map(destination["rooms"], & &1["cash_paid_cents"]) == [3_000, 0]

    assert json_response(get(conn, "/api/v1/payments/source-pay"), 200)["data"] == %{
             "payment_operation_id" => "source-pay",
             "original_group_id" => "source",
             "recorded_cents" => 5_000,
             "held_cents" => 5_000,
             "refunded_cents" => 0,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0,
             "held_by_group" => [
               %{"group_id" => "destination", "amount_cents" => 3_000},
               %{"group_id" => "source", "amount_cents" => 2_000}
             ]
           }

    assert json_response(get(conn, "/api/v1/ledger"), 200)["data"]
           |> Map.take(["cash_held_cents", "cash_reduced_cents", "cash_charged_back_cents"]) == %{
             "cash_held_cents" => 5_000,
             "cash_reduced_cents" => 0,
             "cash_charged_back_cents" => 0
           }
  end

  test "reductions and chargebacks update every group holding the payment", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open_operation("source", "source-open"),
               open_operation("destination", "destination-open"),
               %{
                 "operation_id" => "source-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "source",
                 "amount_cents" => 5_000
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"source_revision" => 3, "destination_revision" => 2}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "transfer-1",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2026-10-05",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 3_000
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 4, "amount_cents" => 1_000}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "reduce-1",
                 "type" => "reduce_cash_payment",
                 "occurred_on" => "2026-10-06",
                 "payment_operation_id" => "source-pay",
                 "amount_cents" => 1_000,
                 "expected_revision" => 3
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/groups/source"), 200)["data"]["revision"] == 4

    assert json_response(get(conn, "/api/v1/groups/destination"), 200)["data"]
           |> Map.take(["revision", "cash_paid_cents"]) == %{
             "revision" => 3,
             "cash_paid_cents" => 2_000
           }

    assert %{"results" => [%{"revision" => 5, "charged_back_cents" => 4_000}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "chargeback-1",
                 "type" => "charge_back_payment",
                 "occurred_on" => "2026-10-07",
                 "payment_operation_id" => "source-pay",
                 "expected_revision" => 4
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/groups/destination"), 200)["data"]
           |> Map.take(["revision", "cash_paid_cents"]) == %{
             "revision" => 4,
             "cash_paid_cents" => 0
           }

    assert json_response(get(conn, "/api/v1/payments/source-pay"), 200)["data"]
           |> Map.take(["held_cents", "reduced_cents", "charged_back_cents"]) == %{
             "held_cents" => 0,
             "reduced_cents" => 1_000,
             "charged_back_cents" => 4_000
           }

    assert json_response(get(conn, "/api/v1/payments/source-pay"), 200)["data"][
             "held_by_group"
           ] == []
  end

  test "resolves both groups and revisions before transfer validation", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 1}]} =
             post_batch(conn, [
               open_operation("source", "source-open"),
               open_operation("destination", "destination-open")
             ])
             |> json_response(200)

    assert post_batch(conn, [
             %{
               "operation_id" => "missing-source",
               "type" => "transfer_deposit",
               "source_group_id" => "missing",
               "destination_group_id" => "also-missing",
               "amount_cents" => 1
             }
           ])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "missing-source",
                 "status" => "rejected",
                 "code" => "group_not_found",
                 "group_id" => "missing"
               }
             ]
           }

    assert post_batch(conn, [
             %{
               "operation_id" => "stale-destination",
               "type" => "transfer_deposit",
               "source_group_id" => "source",
               "destination_group_id" => "destination",
               "amount_cents" => 1,
               "expected_revision" => 1,
               "destination_expected_revision" => 99
             }
           ])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "stale-destination",
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "destination",
                 "expected_revision" => 99,
                 "actual_revision" => 1
               }
             ]
           }

    assert post_batch(conn, [
             %{
               "operation_id" => "invalid-transfer",
               "type" => "transfer_deposit",
               "source_group_id" => "source",
               "destination_group_id" => "source",
               "amount_cents" => 0,
               "expected_revision" => 1
             }
           ])
           |> json_response(200) == %{
             "results" => [
               %{
                 "operation_id" => "invalid-transfer",
                 "status" => "rejected",
                 "code" => "invalid_transfer"
               }
             ]
           }
  end

  test "moves hotel credit without revaluing or resuming its lot", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}]} =
             post_batch(conn, [
               open_operation("credit-source", "credit-source-open", %{
                 "occurred_on" => "2027-01-01",
                 "arrival_on" => "2027-06-10",
                 "departure_on" => "2027-06-13"
               }),
               %{
                 "operation_id" => "credit-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-01",
                 "group_id" => "credit-source",
                 "amount_cents" => 1_000
               },
               %{
                 "operation_id" => "credit-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-01",
                 "group_id" => "credit-source",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open_operation("source", "source-open", %{
                 "occurred_on" => "2027-01-02",
                 "arrival_on" => "2027-06-10",
                 "departure_on" => "2027-06-13"
               }),
               %{
                 "operation_id" => "apply-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "source",
                 "amount_cents" => 1_000
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 1}]} =
             post_batch(conn, [
               open_operation("destination", "destination-open", %{
                 "occurred_on" => "2027-01-02",
                 "arrival_on" => "2027-06-10",
                 "departure_on" => "2027-06-13"
               })
             ])
             |> json_response(200)

    assert %{
             "results" => [
               %{
                 "source_revision" => 3,
                 "destination_revision" => 2,
                 "source_outstanding_deposit_cents" => 5_600,
                 "destination_outstanding_deposit_cents" => 5_400
               }
             ]
           } =
             post_batch(conn, [
               %{
                 "operation_id" => "credit-transfer",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2027-01-03",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 600,
                 "expected_revision" => 2,
                 "destination_expected_revision" => 1
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/guests/guest-transfer/credit?on=2027-01-03"), 200)[
             "data"
           ] == %{
             "guest_id" => "guest-transfer",
             "available_cents" => 100,
             "lots" => [
               %{
                 "source_operation_id" => "credit-cancel",
                 "remaining_cents" => 100,
                 "expires_on" => "2028-01-02"
               }
             ]
           }

    assert %{"results" => [%{"revision" => 3, "credit_issued_cents" => 0}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "cancel-destination",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-04",
                 "group_id" => "destination",
                 "expected_revision" => 2
               }
             ])
             |> json_response(200)

    assert json_response(get(conn, "/api/v1/guests/guest-transfer/credit?on=2027-01-04"), 200)[
             "data"
           ]["available_cents"] == 700

    assert json_response(get(conn, "/api/v1/ledger"), 200)["data"]
           |> Map.take(["cash_held_cents", "cash_converted_to_credit_cents"]) == %{
             "cash_held_cents" => 0,
             "cash_converted_to_credit_cents" => 1_000
           }
  end

  test "takes the newest allocation first across cash and credit", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}]} =
             post_batch(conn, [
               open_operation("credit-maker", "credit-maker-open", %{
                 "occurred_on" => "2027-01-01",
                 "arrival_on" => "2027-06-10",
                 "departure_on" => "2027-06-13"
               }),
               %{
                 "operation_id" => "credit-maker-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-01",
                 "group_id" => "credit-maker",
                 "amount_cents" => 1_000
               },
               %{
                 "operation_id" => "credit-maker-cancel",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-01",
                 "group_id" => "credit-maker",
                 "refund_method" => "hotel_credit"
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}, %{"revision" => 3}]} =
             post_batch(conn, [
               open_operation("source", "source-open", %{
                 "occurred_on" => "2027-01-02",
                 "arrival_on" => "2027-06-10",
                 "departure_on" => "2027-06-13"
               }),
               %{
                 "operation_id" => "source-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "source",
                 "amount_cents" => 1_000
               },
               %{
                 "operation_id" => "source-cash",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2027-01-02",
                 "group_id" => "source",
                 "amount_cents" => 1_000
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"revision" => 1}]} =
             post_batch(conn, [open_operation("destination", "destination-open")])
             |> json_response(200)

    assert %{"results" => [%{"status" => "applied"}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "mixed-transfer",
                 "type" => "transfer_deposit",
                 "occurred_on" => "2027-01-03",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 1_500
               }
             ])
             |> json_response(200)

    source = json_response(get(conn, "/api/v1/groups/source"), 200)["data"]
    destination = json_response(get(conn, "/api/v1/groups/destination"), 200)["data"]

    assert {source["cash_paid_cents"], source["credit_paid_cents"]} == {0, 500}
    assert {destination["cash_paid_cents"], destination["credit_paid_cents"]} == {1_000, 500}
  end

  test "reconstructs a missing payment disposition after selected-room settlement", %{conn: conn} do
    assert %{"results" => [%{"revision" => 1}, %{"revision" => 2}]} =
             post_batch(conn, [
               open_operation("partial", "partial-open", %{
                 "rooms" => [
                   %{"room_id" => "room-a", "nightly_rate_cents" => 10_000},
                   %{"room_id" => "room-b", "nightly_rate_cents" => 10_000}
                 ]
               }),
               %{
                 "operation_id" => "partial-pay",
                 "type" => "record_cash_payment",
                 "occurred_on" => "2026-10-04",
                 "group_id" => "partial",
                 "amount_cents" => 7_000
               }
             ])
             |> json_response(200)

    assert %{"results" => [%{"refunded_cents" => 1_000}]} =
             post_batch(conn, [
               %{
                 "operation_id" => "partial-cancel",
                 "type" => "cancel_rooms",
                 "occurred_on" => "2026-10-05",
                 "group_id" => "partial",
                 "room_ids" => ["room-b"]
               }
             ])
             |> json_response(200)

    Repo.delete!(Repo.get!(PaymentDisposition, "partial-pay"))

    assert json_response(get(conn, "/api/v1/payments/partial-pay"), 200)["data"] == %{
             "payment_operation_id" => "partial-pay",
             "original_group_id" => "partial",
             "recorded_cents" => 7_000,
             "held_cents" => 6_000,
             "refunded_cents" => 1_000,
             "retained_cents" => 0,
             "converted_to_credit_cents" => 0,
             "reduced_cents" => 0,
             "charged_back_cents" => 0
           }

    assert Repo.get(PaymentDisposition, "partial-pay") == nil
  end
end
