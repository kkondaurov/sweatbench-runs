defmodule GroupStayWeb.DepositTransfersControllerTest do
  use GroupStayWeb.ConnCase

  describe "transfer_deposit" do
    test "moves mixed funding in reverse allocation order and retries exactly", %{conn: conn} do
      transfer = transfer_operation("move-funding", "source", "destination", 125)

      operations = [
        open_operation("credit-origin", "guest-1"),
        payment_operation("credit-cash", "credit-origin", 100),
        cancel_operation("issue-credit", "credit-origin", %{"refund_method" => "hotel_credit"}),
        open_operation("source", "guest-1"),
        apply_credit_operation("apply-credit", "source", 100),
        payment_operation("pay-first", "source", 50),
        payment_operation("pay-last", "source", 50),
        open_operation("destination", "guest-1"),
        transfer,
        transfer
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      original = Enum.at(results, -2)
      retried = List.last(results)

      assert original == retried

      assert original == %{
               "operation_id" => "move-funding",
               "status" => "applied",
               "source_group_id" => "source",
               "destination_group_id" => "destination",
               "amount_cents" => 125,
               "source_outstanding_deposit_cents" => 225,
               "destination_outstanding_deposit_cents" => 175,
               "source_revision" => 5,
               "destination_revision" => 2
             }

      assert %{
               "data" => %{
                 "cash_paid_cents" => 0,
                 "credit_paid_cents" => 75,
                 "rooms" => [
                   %{"room_id" => "room-a", "credit_paid_cents" => 75},
                   %{"room_id" => "room-b", "credit_paid_cents" => 0},
                   %{"room_id" => "room-c", "credit_paid_cents" => 0}
                 ]
               }
             } = get_group("source")

      assert %{
               "data" => %{
                 "cash_paid_cents" => 100,
                 "credit_paid_cents" => 25,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "cash_paid_cents" => 100,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 25
                   },
                   %{"room_id" => "room-c", "cash_paid_cents" => 0}
                 ]
               }
             } = get_group("destination")

      assert %{
               "data" => %{
                 "held_cents" => 50,
                 "held_by_group" => [%{"group_id" => "destination", "amount_cents" => 50}]
               }
             } = get_payment("pay-first")

      refute Map.has_key?(get_payment("credit-cash")["data"], "held_by_group")

      assert %{
               "data" => %{
                 "cash_held_cents" => 100,
                 "credit_liability_cents" => 110,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0
               }
             } = get_ledger()

      assert %{"data" => ^original} =
               build_conn()
               |> get("/api/v1/operations/move-funding")
               |> json_response(200)
    end

    test "resolves groups and revision guards before transfer validation", %{conn: conn} do
      operations = [
        open_operation("source", "guest-1"),
        payment_operation("pay-source", "source", 100),
        open_operation("destination", "guest-1"),
        payment_operation("pay-destination", "destination", 250),
        open_operation("other-guest", "guest-2"),
        open_operation("inactive", "guest-1"),
        cancel_operation("cancel-inactive", "inactive"),
        transfer_operation("missing-source", "absent-source", "absent-destination", 1, %{
          "expected_revision" => "bad"
        }),
        transfer_operation("missing-destination", "source", "absent-destination", 1),
        transfer_operation("stale-source", "source", "destination", 0, %{
          "expected_revision" => 99,
          "destination_expected_revision" => 99
        }),
        transfer_operation("stale-destination", "source", "destination", 0, %{
          "expected_revision" => 2,
          "destination_expected_revision" => 99
        }),
        transfer_operation("same", "source", "source", 1),
        transfer_operation("different-guest", "source", "other-guest", 1),
        transfer_operation("inactive-destination", "source", "inactive", 1),
        transfer_operation("invalid-amount", "source", "destination", 0),
        transfer_operation("excess-held", "source", "destination", 101),
        transfer_operation("excess-outstanding", "source", "destination", 100)
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)

      rejected = Map.new(Enum.drop(results, 7), &{&1["operation_id"], &1})

      assert rejected["missing-source"]["code"] == "group_not_found"
      assert rejected["missing-source"]["group_id"] == "absent-source"
      assert rejected["missing-destination"]["group_id"] == "absent-destination"

      assert %{
               "code" => "stale_revision",
               "group_id" => "source",
               "expected_revision" => 99,
               "actual_revision" => 2
             } = rejected["stale-source"]

      assert %{
               "code" => "stale_revision",
               "group_id" => "destination",
               "expected_revision" => 99,
               "actual_revision" => 2
             } = rejected["stale-destination"]

      assert rejected["same"]["code"] == "invalid_transfer"
      assert rejected["different-guest"]["code"] == "invalid_transfer"

      assert %{"code" => "group_not_active", "group_id" => "inactive"} =
               rejected["inactive-destination"]

      assert rejected["invalid-amount"]["code"] == "invalid_amount"
      assert rejected["excess-held"]["code"] == "transfer_exceeds_held_funding"
      assert rejected["excess-outstanding"]["code"] == "transfer_exceeds_outstanding"

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 100}} =
               get_group("source")

      assert %{"data" => %{"revision" => 2, "cash_paid_cents" => 250}} =
               get_group("destination")
    end

    test "reductions follow transferred cash and increment every changed group once", %{
      conn: conn
    } do
      setup_operations = [
        open_operation("source", "guest-1"),
        payment_operation("pay-source", "source", 150),
        open_operation("destination", "guest-1"),
        transfer_operation("move-part", "source", "destination", 50)
      ]

      assert %{"results" => [_, _, _, moved]} =
               conn |> post_batch(setup_operations) |> json_response(200)

      assert moved["source_revision"] == 3
      assert moved["destination_revision"] == 2

      assert %{
               "data" => %{
                 "held_cents" => 150,
                 "held_by_group" => [
                   %{"group_id" => "destination", "amount_cents" => 50},
                   %{"group_id" => "source", "amount_cents" => 100}
                 ]
               }
             } = get_payment("pay-source")

      assert %{"results" => [reduced]} =
               build_conn()
               |> post_batch([reduce_operation("reduce-across-groups", "pay-source", 120)])
               |> json_response(200)

      assert reduced == %{
               "operation_id" => "reduce-across-groups",
               "status" => "applied",
               "payment_operation_id" => "pay-source",
               "group_id" => "source",
               "amount_cents" => 120,
               "outstanding_deposit_cents" => 270,
               "revision" => 4
             }

      assert %{"data" => %{"revision" => 4, "cash_paid_cents" => 30}} = get_group("source")

      assert %{"data" => %{"revision" => 3, "cash_paid_cents" => 0}} =
               get_group("destination")

      assert %{
               "data" => %{
                 "held_cents" => 30,
                 "held_by_group" => [%{"group_id" => "source", "amount_cents" => 30}]
               }
             } = get_payment("pay-source")
    end

    test "destination policy settles transferred cash and chargeback revises both groups", %{
      conn: conn
    } do
      operations = [
        open_operation("source", "guest-1"),
        payment_operation("pay-source", "source", 100),
        open_operation("destination", "guest-1", %{"rate_plan" => "advance_purchase"}),
        transfer_operation("move-cash", "source", "destination", 100),
        cancel_operation("cancel-destination", "destination"),
        chargeback_operation("chargeback-source", "pay-source")
      ]

      assert %{"results" => [_, _, _, _, cancelled, charged_back]} =
               conn |> post_batch(operations) |> json_response(200)

      assert cancelled["refunded_cents"] == 0
      assert cancelled["retained_cents"] == 100
      assert charged_back["charged_back_cents"] == 100
      assert charged_back["revision"] == 4

      assert %{"data" => %{"revision" => 4}} = get_group("source")

      assert %{"data" => %{"revision" => 4, "status" => "cancelled"}} =
               get_group("destination")

      assert %{
               "data" => %{
                 "cash_retained_cents" => 0,
                 "cash_charged_back_cents" => 100
               }
             } = get_ledger()

      assert %{"data" => %{"held_by_group" => []}} = get_payment("pay-source")
    end

    test "chargeback revokes credit issued from transferred cash without revising its funded group",
         %{
           conn: conn
         } do
      operations = [
        open_operation("source", "guest-1"),
        payment_operation("pay-source", "source", 100),
        open_operation("destination", "guest-1"),
        transfer_operation("move-cash", "source", "destination", 100),
        cancel_operation("convert-destination", "destination", %{
          "refund_method" => "hotel_credit"
        }),
        open_operation("credit-target", "guest-1"),
        apply_credit_operation("apply-issued-credit", "credit-target", 110),
        chargeback_operation("chargeback-source", "pay-source")
      ]

      assert %{"results" => [_, _, _, _, converted, _, _, charged_back]} =
               conn |> post_batch(operations) |> json_response(200)

      assert converted["credit_issued_cents"] == 110
      assert charged_back["charged_back_cents"] == 100
      assert charged_back["revision"] == 4

      assert %{"data" => %{"revision" => 4}} = get_group("source")
      assert %{"data" => %{"revision" => 4}} = get_group("destination")

      assert %{"data" => %{"revision" => 2, "credit_paid_cents" => 110}} =
               get_group("credit-target")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 0,
                 "cash_charged_back_cents" => 100,
                 "credit_liability_cents" => 110,
                 "credit_shortfall_cents" => 110
               }
             } = get_ledger()
    end

    test "moves applied credit after its expiry without resuming expiry", %{conn: conn} do
      operations = [
        open_operation("credit-origin", "guest-1"),
        payment_operation("credit-cash", "credit-origin", 100),
        cancel_operation("issue-credit", "credit-origin", %{
          "occurred_on" => "2027-01-03",
          "refund_method" => "hotel_credit"
        }),
        open_operation("source", "guest-1", %{
          "arrival_on" => "2030-12-10",
          "departure_on" => "2030-12-11"
        }),
        apply_credit_operation("apply-before-expiry", "source", 100),
        open_operation("destination", "guest-1", %{
          "arrival_on" => "2030-12-10",
          "departure_on" => "2030-12-11"
        }),
        transfer_operation("move-expired-credit", "source", "destination", 100, %{
          "occurred_on" => "2029-01-01"
        }),
        cancel_operation("restore-after-expiry", "destination", %{
          "occurred_on" => "2029-01-02"
        })
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))
      assert Enum.at(results, 6)["amount_cents"] == 100
      assert List.last(results)["credit_issued_cents"] == 0

      assert %{"data" => %{"credit_liability_cents" => 0}} =
               build_conn()
               |> get("/api/v1/ledger?on=2029-01-02")
               |> json_response(200)
    end
  end

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  defp get_group(group_id) do
    build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200)
  end

  defp get_payment(payment_operation_id) do
    build_conn()
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
  end

  defp get_ledger do
    build_conn() |> get("/api/v1/ledger?on=2027-01-10") |> json_response(200)
  end

  defp open_operation(group_id, guest_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "open-#{group_id}",
        "type" => "open_group",
        "occurred_on" => "2027-01-01",
        "group_id" => group_id,
        "guest_id" => guest_id,
        "property_id" => "ams-canal",
        "arrival_on" => "2027-12-10",
        "departure_on" => "2027-12-11",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 500},
          %{"room_id" => "room-b", "nightly_rate_cents" => 500},
          %{"room_id" => "room-c", "nightly_rate_cents" => 500}
        ]
      },
      overrides
    )
  end

  defp payment_operation(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "record_cash_payment",
      "occurred_on" => "2027-01-02",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp apply_credit_operation(operation_id, group_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "apply_hotel_credit",
      "occurred_on" => "2027-01-04",
      "group_id" => group_id,
      "amount_cents" => amount
    }
  end

  defp transfer_operation(operation_id, source, destination, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "transfer_deposit",
        "occurred_on" => "2027-01-05",
        "source_group_id" => source,
        "destination_group_id" => destination,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp cancel_operation(operation_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => "2027-01-03",
        "group_id" => group_id
      },
      overrides
    )
  end

  defp reduce_operation(operation_id, payment_operation_id, amount) do
    %{
      "operation_id" => operation_id,
      "type" => "reduce_cash_payment",
      "occurred_on" => "2027-01-06",
      "payment_operation_id" => payment_operation_id,
      "amount_cents" => amount
    }
  end

  defp chargeback_operation(operation_id, payment_operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-06",
      "payment_operation_id" => payment_operation_id
    }
  end
end
