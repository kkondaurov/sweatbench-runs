defmodule GroupStayWeb.RoomAccountingControllerTest do
  use GroupStayWeb.ConnCase

  describe "room accounting and selected cancellation" do
    test "allocates by room order and settles only selected active rooms", %{conn: conn} do
      operations = [
        open_operation("group-1", "guest-1"),
        payment_operation("pay-1", "group-1", 150),
        cancel_rooms_operation("cancel-middle", "group-1", ["room-b"])
      ]

      assert %{"results" => [_, _, cancelled]} =
               conn |> post_batch(operations) |> json_response(200)

      assert cancelled == %{
               "operation_id" => "cancel-middle",
               "status" => "applied",
               "group_id" => "group-1",
               "cancelled_room_ids" => ["room-b"],
               "refunded_cents" => 50,
               "retained_cents" => 0,
               "credit_issued_cents" => 0,
               "revision" => 3
             }

      assert %{
               "data" => %{
                 "status" => "active",
                 "lodging_total_cents" => 1_000,
                 "deposit_due_cents" => 200,
                 "deposit_paid_cents" => 100,
                 "cash_paid_cents" => 100,
                 "outstanding_deposit_cents" => 100,
                 "rooms" => [
                   %{
                     "room_id" => "room-a",
                     "status" => "active",
                     "lodging_total_cents" => 500,
                     "deposit_due_cents" => 100,
                     "cash_paid_cents" => 100,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-b",
                     "status" => "cancelled",
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   },
                   %{
                     "room_id" => "room-c",
                     "status" => "active",
                     "cash_paid_cents" => 0,
                     "credit_paid_cents" => 0
                   }
                 ]
               }
             } = get_group("group-1")

      assert %{"data" => %{"cash_held_cents" => 100, "cash_refunded_cents" => 50}} =
               get_ledger()
    end

    test "returns selected rooms in original order and cancels the group after the last rooms", %{
      conn: conn
    } do
      operations = [
        open_operation("group-1", "guest-1"),
        cancel_rooms_operation("cancel-first", "group-1", ["room-b"]),
        cancel_rooms_operation("cancel-rest", "group-1", ["room-c", "room-a"])
      ]

      assert %{"results" => [_, _, cancelled]} =
               conn |> post_batch(operations) |> json_response(200)

      assert cancelled["cancelled_room_ids"] == ["room-a", "room-c"]

      assert %{"data" => %{"status" => "cancelled", "deposit_due_cents" => 0}} =
               get_group("group-1")
    end

    test "rejects the whole selection for duplicate, missing, or cancelled rooms", %{conn: conn} do
      operations = [
        open_operation("group-1", "guest-1"),
        cancel_rooms_operation("cancel-a", "group-1", ["room-a"]),
        cancel_rooms_operation("duplicate", "group-1", ["room-b", "room-b"]),
        cancel_rooms_operation("missing", "group-1", ["absent"]),
        cancel_rooms_operation("already-cancelled", "group-1", ["room-a"])
      ]

      assert %{"results" => [_, _, duplicate, missing, inactive]} =
               conn |> post_batch(operations) |> json_response(200)

      assert Enum.map([duplicate, missing, inactive], & &1["code"]) ==
               ~w(invalid_rooms invalid_rooms invalid_rooms)

      assert %{"data" => %{"revision" => 2, "deposit_due_cents" => 200}} =
               get_group("group-1")
    end

    test "reports invalid rooms after the final room has already been cancelled", %{conn: conn} do
      operations = [
        open_operation("group-1", "guest-1"),
        cancel_group_operation("cancel-all", "group-1"),
        cancel_rooms_operation("cancel-again", "group-1", ["room-a"])
      ]

      assert %{"results" => [_, _, rejected]} =
               conn |> post_batch(operations) |> json_response(200)

      assert rejected["code"] == "invalid_rooms"
    end
  end

  describe "payment reductions and statements" do
    test "reduces one payment in reverse fill order and preserves its durable result", %{
      conn: conn
    } do
      payment = payment_operation("pay-1", "group-1", 150)

      operations = [
        open_operation("group-1", "guest-1"),
        payment,
        payment_operation("pay-2", "group-1", 50),
        reduce_operation("reduce-1", "pay-1", 60)
      ]

      assert %{"results" => [_, original, _, reduced]} =
               conn |> post_batch(operations) |> json_response(200)

      assert reduced["outstanding_deposit_cents"] == 160
      assert reduced["revision"] == 4

      assert %{
               "data" => %{
                 "rooms" => [
                   %{"room_id" => "room-a", "cash_paid_cents" => 90},
                   %{"room_id" => "room-b", "cash_paid_cents" => 50},
                   %{"room_id" => "room-c", "cash_paid_cents" => 0}
                 ]
               }
             } = get_group("group-1")

      assert get_payment("pay-1") == %{
               "data" => %{
                 "payment_operation_id" => "pay-1",
                 "original_group_id" => "group-1",
                 "recorded_cents" => 150,
                 "held_cents" => 90,
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "converted_to_credit_cents" => 0,
                 "reduced_cents" => 60,
                 "charged_back_cents" => 0
               }
             }

      assert %{"results" => [retried]} =
               build_conn() |> post_batch([payment]) |> json_response(200)

      assert retried == original

      assert %{"data" => %{"cash_held_cents" => 140, "cash_reduced_cents" => 60}} =
               get_ledger()
    end

    test "uses the reduction-specific errors and checks revisions first", %{conn: conn} do
      operations = [
        open_operation("group-1", "guest-1"),
        payment_operation("pay-1", "group-1", 50),
        reduce_operation("stale", "pay-1", -1, %{"expected_revision" => 1}),
        reduce_operation("invalid", "pay-1", 0),
        reduce_operation("excess", "pay-1", 51),
        reduce_operation("all", "pay-1", 50),
        reduce_operation("empty", "pay-1", 1),
        reduce_operation("unknown", "absent", 1)
      ]

      assert %{"results" => [_, _, stale, invalid, excess, _, empty, unknown]} =
               conn |> post_batch(operations) |> json_response(200)

      assert stale["code"] == "stale_revision"
      assert invalid["code"] == "invalid_amount"
      assert excess["code"] == "reduction_exceeds_held_cash"
      assert empty["code"] == "payment_not_reducible"
      assert unknown["code"] == "operation_not_found"

      assert json_response(get(build_conn(), "/api/v1/payments/never-submitted"), 404) == %{
               "error" => %{"code" => "operation_not_found"}
             }

      assert json_response(get(build_conn(), "/api/v1/payments/open-group-1"), 422) == %{
               "error" => %{"code" => "payment_not_reconcilable"}
             }
    end

    test "can repay a fully reduced large payment without overflowing group state", %{conn: conn} do
      amount = 7_500_000_000_000_000_000

      opened =
        open_operation("large", "guest-large")
        |> Map.merge(%{
          "rate_plan" => "advance_purchase",
          "rooms" => [%{"room_id" => "large-room", "nightly_rate_cents" => amount}]
        })

      operations = [
        opened,
        payment_operation("pay-large-1", "large", amount),
        reduce_operation("reduce-large", "pay-large-1", amount),
        payment_operation("pay-large-2", "large", amount)
      ]

      assert %{"results" => results} = conn |> post_batch(operations) |> json_response(200)
      assert Enum.all?(results, &(&1["status"] == "applied"))

      assert %{
               "data" => %{
                 "cash_held_cents" => ^amount,
                 "cash_reduced_cents" => ^amount
               }
             } = get_ledger()
    end
  end

  describe "payment chargebacks" do
    test "reclassifies refunded cash without repeating the historical refund", %{conn: conn} do
      operations = [
        open_operation("group-1", "guest-1"),
        payment_operation("pay-1", "group-1", 150),
        cancel_group_operation("cancel-1", "group-1"),
        chargeback_operation("chargeback-1", "pay-1")
      ]

      assert %{"results" => [_, _, _, chargeback]} =
               conn |> post_batch(operations) |> json_response(200)

      assert chargeback["charged_back_cents"] == 150
      assert chargeback["revision"] == 4

      assert %{
               "data" => %{
                 "cash_refunded_cents" => 0,
                 "cash_charged_back_cents" => 150,
                 "cash_held_cents" => 0
               }
             } = get_ledger()

      assert %{
               "data" => %{
                 "recorded_cents" => 150,
                 "refunded_cents" => 0,
                 "charged_back_cents" => 150
               }
             } = get_payment("pay-1")
    end

    test "charges back every non-reduced held cent and retries exactly", %{conn: conn} do
      chargeback = chargeback_operation("chargeback-1", "pay-1")

      operations = [
        open_operation("group-1", "guest-1"),
        payment_operation("pay-1", "group-1", 150),
        reduce_operation("reduce-1", "pay-1", 60),
        chargeback,
        chargeback
      ]

      assert %{"results" => [_, _, _, original, retried]} =
               conn |> post_batch(operations) |> json_response(200)

      assert original == retried
      assert original["charged_back_cents"] == 90
      assert original["outstanding_deposit_cents"] == 300

      assert %{
               "data" => %{
                 "recorded_cents" => 150,
                 "held_cents" => 0,
                 "reduced_cents" => 60,
                 "charged_back_cents" => 90
               }
             } = get_payment("pay-1")

      assert %{
               "data" => %{
                 "cash_reduced_cents" => 60,
                 "cash_charged_back_cents" => 90
               }
             } = get_ledger()
    end

    test "telescopes multi-payment bonus entitlements for one credit lot", %{conn: conn} do
      operations = [
        open_operation("source", "guest-1"),
        payment_operation("pay-first", "source", 4),
        payment_operation("pay-second", "source", 1),
        cancel_group_operation("issue-credit", "source", %{"refund_method" => "hotel_credit"}),
        chargeback_operation("chargeback-first", "pay-first")
      ]

      assert %{"results" => [_, _, _, issued, charged_back]} =
               conn |> post_batch(operations) |> json_response(200)

      assert issued["credit_issued_cents"] == 6
      assert charged_back["charged_back_cents"] == 4

      assert %{
               "data" => %{
                 "available_cents" => 2,
                 "lots" => [%{"source_operation_id" => "issue-credit", "remaining_cents" => 2}]
               }
             } =
               build_conn()
               |> get("/api/v1/guests/guest-1/credit?on=2027-01-10")
               |> json_response(200)

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 1,
                 "cash_charged_back_cents" => 4,
                 "credit_liability_cents" => 2
               }
             } = get_ledger()
    end

    test "reports and absorbs a credit shortfall without changing the funded group revision", %{
      conn: conn
    } do
      source = [
        open_operation("source", "guest-1"),
        payment_operation("pay-source", "source", 100),
        cancel_group_operation("issue-credit", "source", %{"refund_method" => "hotel_credit"})
      ]

      target = [
        open_operation("target", "guest-1"),
        apply_credit_operation("apply-credit", "target", 110),
        chargeback_operation("chargeback-source", "pay-source")
      ]

      assert %{"results" => results} =
               conn |> post_batch(source ++ target) |> json_response(200)

      assert List.last(results)["charged_back_cents"] == 100

      assert %{"data" => %{"revision" => 2, "credit_paid_cents" => 110}} =
               get_group("target")

      assert %{
               "data" => %{
                 "cash_converted_to_credit_cents" => 0,
                 "cash_charged_back_cents" => 100,
                 "credit_liability_cents" => 110,
                 "credit_shortfall_cents" => 110
               }
             } = get_ledger()

      assert %{"results" => [%{"status" => "applied"}]} =
               build_conn()
               |> post_batch([cancel_group_operation("cancel-target", "target")])
               |> json_response(200)

      assert %{
               "data" => %{
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               }
             } = get_ledger()

      assert %{"data" => %{"available_cents" => 0}} =
               build_conn()
               |> get("/api/v1/guests/guest-1/credit?on=2027-01-10")
               |> json_response(200)
    end
  end

  defp post_batch(conn, operations) do
    post(conn, "/api/v1/partner-batches", %{"operations" => operations})
  end

  defp get_group(group_id) do
    build_conn() |> get("/api/v1/groups/#{group_id}") |> json_response(200)
  end

  defp get_ledger do
    build_conn() |> get("/api/v1/ledger?on=2027-01-10") |> json_response(200)
  end

  defp get_payment(payment_operation_id) do
    build_conn()
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
  end

  defp open_operation(group_id, guest_id) do
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
    }
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

  defp cancel_rooms_operation(operation_id, group_id, room_ids) do
    %{
      "operation_id" => operation_id,
      "type" => "cancel_rooms",
      "occurred_on" => "2027-01-03",
      "group_id" => group_id,
      "room_ids" => room_ids
    }
  end

  defp cancel_group_operation(operation_id, group_id, overrides \\ %{}) do
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

  defp reduce_operation(operation_id, payment_operation_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "reduce_cash_payment",
        "occurred_on" => "2027-01-04",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp chargeback_operation(operation_id, payment_operation_id) do
    %{
      "operation_id" => operation_id,
      "type" => "charge_back_payment",
      "occurred_on" => "2027-01-05",
      "payment_operation_id" => payment_operation_id
    }
  end
end
