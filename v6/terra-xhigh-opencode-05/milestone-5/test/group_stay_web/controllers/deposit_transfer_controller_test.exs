defmodule GroupStayWeb.DepositTransferControllerTest do
  use GroupStayWeb.ConnCase, async: false

  test "moves cash in reverse allocation order, preserves payment provenance, and is idempotent",
       %{
         conn: conn
       } do
    assert %{"results" => results} =
             post_batch(conn, [
               two_room_group("open-source", "source", "guest-1"),
               two_room_group("open-destination", "destination", "guest-1"),
               cash_payment("pay-old", "source", 30),
               cash_payment("pay-new", "source", 20)
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    transfer = transfer("transfer-1", "source", "destination", 40, 3, 1)

    assert %{
             "results" => [
               %{
                 "operation_id" => "transfer-1",
                 "status" => "applied",
                 "source_group_id" => "source",
                 "destination_group_id" => "destination",
                 "amount_cents" => 40,
                 "source_outstanding_deposit_cents" => 50,
                 "destination_outstanding_deposit_cents" => 20,
                 "source_revision" => 4,
                 "destination_revision" => 2
               } = transfer_result
             ]
           } = post_batch(build_conn(), [transfer]) |> json_response(200)

    assert %{
             "data" => %{
               "cash_paid_cents" => 10,
               "outstanding_deposit_cents" => 50,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 10},
                 %{"room_id" => "room-b", "cash_paid_cents" => 0}
               ]
             }
           } = get(build_conn(), "/api/v1/groups/source") |> json_response(200)

    assert %{
             "data" => %{
               "cash_paid_cents" => 40,
               "outstanding_deposit_cents" => 20,
               "rooms" => [
                 %{"room_id" => "room-a", "cash_paid_cents" => 20},
                 %{"room_id" => "room-b", "cash_paid_cents" => 20}
               ]
             }
           } = get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 30,
               "held_by_group" => [
                 %{"group_id" => "destination", "amount_cents" => 20},
                 %{"group_id" => "source", "amount_cents" => 10}
               ]
             }
           } = get(build_conn(), "/api/v1/payments/pay-old") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 20,
               "held_by_group" => [%{"group_id" => "destination", "amount_cents" => 20}]
             }
           } = get(build_conn(), "/api/v1/payments/pay-new") |> json_response(200)

    assert %{"data" => %{"cash_held_cents" => 50}} =
             get(build_conn(), "/api/v1/ledger") |> json_response(200)

    assert %{"results" => [^transfer_result]} =
             post_batch(build_conn(), [transfer]) |> json_response(200)

    assert %{"data" => ^transfer_result} =
             get(build_conn(), "/api/v1/operations/transfer-1") |> json_response(200)
  end

  test "keeps transferred credit in its original lot and restores it on destination cancellation",
       %{
         conn: conn
       } do
    assert %{"results" => results} =
             post_batch(conn, [
               one_room_group("open-credit-source", "credit-source", "guest-1"),
               cash_payment("pay-credit-source", "credit-source", 20),
               %{
                 "operation_id" => "issue-credit",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-10",
                 "group_id" => "credit-source",
                 "refund_method" => "hotel_credit"
               },
               two_room_group("open-source", "source", "guest-1"),
               %{
                 "operation_id" => "apply-credit",
                 "type" => "apply_hotel_credit",
                 "occurred_on" => "2027-01-11",
                 "group_id" => "source",
                 "amount_cents" => 22
               },
               one_room_group("open-destination", "destination", "guest-1"),
               transfer("transfer-credit", "source", "destination", 10, 2, 1),
               %{
                 "operation_id" => "cancel-destination",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-12",
                 "group_id" => "destination"
               }
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "data" => %{
               "credit_paid_cents" => 12,
               "outstanding_deposit_cents" => 48
             }
           } = get(build_conn(), "/api/v1/groups/source") |> json_response(200)

    assert %{
             "data" => %{
               "available_cents" => 10,
               "lots" => [
                 %{
                   "source_operation_id" => "issue-credit",
                   "remaining_cents" => 10,
                   "expires_on" => "2028-01-11"
                 }
               ]
             }
           } =
             get(build_conn(), "/api/v1/guests/guest-1/credit?on=2027-01-12")
             |> json_response(200)

    assert %{"data" => %{"credit_liability_cents" => 22}} =
             get(build_conn(), "/api/v1/ledger?on=2027-01-12") |> json_response(200)
  end

  test "validates groups, revisions, amounts, and available funding in transfer order", %{
    conn: conn
  } do
    assert %{"results" => results} =
             post_batch(conn, [
               two_room_group("open-source", "source", "guest-1"),
               one_room_group("open-destination", "destination", "guest-1"),
               one_room_group("open-other", "other", "guest-2"),
               cash_payment("pay-source", "source", 30)
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert_transfer_rejection(
      "missing-source",
      transfer("missing-source", "missing", "destination", 1),
      "group_not_found",
      "missing"
    )

    assert_transfer_rejection(
      "missing-destination",
      transfer("missing-destination", "source", "missing", 1),
      "group_not_found",
      "missing"
    )

    assert_transfer_rejection(
      "stale-source",
      transfer("stale-source", "source", "destination", 0, 1, 1),
      "stale_revision",
      "source"
    )

    assert_transfer_rejection(
      "stale-destination",
      transfer("stale-destination", "source", "destination", 0, 2, 0),
      "stale_revision",
      "destination"
    )

    assert_transfer_rejection(
      "same-group",
      transfer("same-group", "source", "source", 1),
      "invalid_transfer"
    )

    assert_transfer_rejection(
      "different-guests",
      transfer("different-guests", "source", "other", 1),
      "invalid_transfer"
    )

    assert_transfer_rejection(
      "invalid-amount",
      transfer("invalid-amount", "source", "destination", 0),
      "invalid_amount"
    )

    assert_transfer_rejection(
      "too-much-held",
      transfer("too-much-held", "source", "destination", 31),
      "transfer_exceeds_held_funding"
    )

    assert_transfer_rejection(
      "too-much-outstanding",
      transfer("too-much-outstanding", "source", "destination", 21),
      "transfer_exceeds_outstanding"
    )

    assert %{"results" => [%{"status" => "applied", "revision" => 2}]} =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "cancel-destination",
                 "type" => "cancel_group",
                 "occurred_on" => "2027-01-10",
                 "group_id" => "destination"
               }
             ])
             |> json_response(200)

    assert_transfer_rejection(
      "inactive-destination",
      transfer("inactive-destination", "source", "destination", 1),
      "group_not_active",
      "destination"
    )
  end

  test "payment corrections update every group that still holds transferred cash", %{conn: conn} do
    assert %{"results" => results} =
             post_batch(conn, [
               one_room_group("open-source", "source", "guest-1"),
               one_room_group("open-destination", "destination", "guest-1"),
               cash_payment("pay-source", "source", 20),
               transfer("transfer-cash", "source", "destination", 20)
             ])
             |> json_response(200)

    assert Enum.all?(results, &(&1["status"] == "applied"))

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "group_id" => "source",
                 "outstanding_deposit_cents" => 20,
                 "revision" => 4
               }
             ]
           } =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "reduce-payment",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "pay-source",
                 "amount_cents" => 10,
                 "expected_revision" => 3
               }
             ])
             |> json_response(200)

    assert %{"data" => %{"revision" => 3, "outstanding_deposit_cents" => 10}} =
             get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 10,
               "held_by_group" => [%{"group_id" => "destination", "amount_cents" => 10}],
               "reduced_cents" => 10
             }
           } = get(build_conn(), "/api/v1/payments/pay-source") |> json_response(200)

    assert %{
             "results" => [
               %{
                 "status" => "applied",
                 "group_id" => "source",
                 "charged_back_cents" => 10,
                 "revision" => 5
               }
             ]
           } =
             post_batch(build_conn(), [
               %{
                 "operation_id" => "chargeback-payment",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "pay-source",
                 "expected_revision" => 4
               }
             ])
             |> json_response(200)

    assert %{"data" => %{"revision" => 4, "outstanding_deposit_cents" => 20}} =
             get(build_conn(), "/api/v1/groups/destination") |> json_response(200)

    assert %{
             "data" => %{
               "held_cents" => 0,
               "held_by_group" => [],
               "reduced_cents" => 10,
               "charged_back_cents" => 10
             }
           } = get(build_conn(), "/api/v1/payments/pay-source") |> json_response(200)
  end

  defp assert_transfer_rejection(operation_id, operation, code, group_id \\ nil) do
    assert %{"results" => [result]} = post_batch(build_conn(), [operation]) |> json_response(200)
    assert result["operation_id"] == operation_id
    assert result["status"] == "rejected"
    assert result["code"] == code

    if group_id do
      assert result["group_id"] == group_id
    end
  end

  defp post_batch(conn, operations),
    do: post(conn, "/api/v1/partner-batches", %{operations: operations})

  defp transfer(operation_id, source_group_id, destination_group_id, amount_cents) do
    transfer(operation_id, source_group_id, destination_group_id, amount_cents, nil, nil)
  end

  defp transfer(
         operation_id,
         source_group_id,
         destination_group_id,
         amount_cents,
         expected_revision,
         destination_expected_revision
       ) do
    %{
      "operation_id" => operation_id,
      "type" => "transfer_deposit",
      "source_group_id" => source_group_id,
      "destination_group_id" => destination_group_id,
      "amount_cents" => amount_cents
    }
    |> maybe_put("expected_revision", expected_revision)
    |> maybe_put("destination_expected_revision", destination_expected_revision)
  end

  defp two_room_group(operation_id, group_id, guest_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2027-04-01",
      "departure_on" => "2027-04-02",
      "rate_plan" => "flexible",
      "rooms" => [
        %{"room_id" => "room-a", "nightly_rate_cents" => 100},
        %{"room_id" => "room-b", "nightly_rate_cents" => 200}
      ]
    }
  end

  defp one_room_group(operation_id, group_id, guest_id) do
    %{
      "operation_id" => operation_id,
      "type" => "open_group",
      "occurred_on" => "2027-01-01",
      "group_id" => group_id,
      "guest_id" => guest_id,
      "property_id" => "ams-canal",
      "arrival_on" => "2027-04-01",
      "departure_on" => "2027-04-02",
      "rate_plan" => "flexible",
      "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 100}]
    }
  end

  defp cash_payment(operation_id, group_id, amount_cents) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount_cents
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
