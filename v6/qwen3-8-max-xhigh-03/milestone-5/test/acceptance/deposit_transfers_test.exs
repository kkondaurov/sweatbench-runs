defmodule GroupStayWeb.DepositTransfersAcceptanceTest do
  @moduledoc """
  End-to-end walkthrough of deposit transfers: held funding moves between two
  active groups of one guest without settling or revaluing, reductions and
  chargebacks follow a payment's allocations across groups, and a payment's
  statement reports its held cash by group once it has participated in a
  transfer.
  """

  use GroupStayWeb.ConnCase

  alias GroupStay.Repo

  @batch_path "/api/v1/partner-batches"

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(@batch_path, Jason.encode!(%{operations: operations}))
  end

  defp run(conn, operations) do
    submit(conn, operations) |> json_response(200) |> Map.fetch!("results")
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
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15_000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17_500}
        ]
      },
      overrides
    )
  end

  # group-92: same guest, deposits of 6_000 and 7_200 (13_200 total).
  defp second_open_op(overrides \\ %{}) do
    Map.merge(
      open_op(%{
        "operation_id" => "op-open-92",
        "group_id" => "group-92",
        "rooms" => [
          %{"room_id" => "room-c", "nightly_rate_cents" => 10_000},
          %{"room_id" => "room-d", "nightly_rate_cents" => 12_000}
        ]
      }),
      overrides
    )
  end

  defp payment_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-pay",
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp transfer_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 5_000
      },
      overrides
    )
  end

  defp cancel_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel",
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-92"
      },
      overrides
    )
  end

  defp reduce_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => "op-pay",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp chargeback_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-06",
        "payment_operation_id" => "op-pay"
      },
      overrides
    )
  end

  defp credit_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-credit",
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-05",
        "group_id" => "group-81",
        "amount_cents" => 1_500
      },
      overrides
    )
  end

  defp fetched_group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp room(fetched, room_id) do
    Enum.find(fetched["rooms"], &(&1["room_id"] == room_id))
  end

  defp ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp guest_credit(conn, guest_id \\ "guest-22") do
    conn
    |> get("/api/v1/guests/#{guest_id}/credit")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp statement(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  # Opens a funder group, pays it, and cancels it into hotel credit so the
  # guest holds one credit lot.
  defp issue_credit(conn, cancel_op_id, group_id, cash_cents) do
    run(conn, [
      open_op(%{"operation_id" => cancel_op_id <> "-open", "group_id" => group_id}),
      payment_op(%{
        "operation_id" => cancel_op_id <> "-pay",
        "group_id" => group_id,
        "amount_cents" => cash_cents
      }),
      %{
        "operation_id" => cancel_op_id,
        "type" => "cancel_group",
        "occurred_on" => "2026-10-04",
        "group_id" => group_id,
        "refund_method" => "hotel_credit"
      }
    ])
  end

  # Opens group-81 and group-92 for the same guest and pays group-81.
  defp open_pair(conn, pay_cents) do
    assert [_] = run(conn, [open_op()])
    assert [_] = run(conn, [second_open_op()])
    assert [_] = run(conn, [payment_op(%{"amount_cents" => pay_cents})])
  end

  describe "transfer_deposit" do
    test "moves held cash between two active groups of the same guest", %{conn: conn} do
      open_pair(conn, 12_000)

      assert [result] = run(conn, [transfer_op()])

      assert result == %{
               "operation_id" => "op-transfer",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-92",
               "amount_cents" => 5_000,
               "source_outstanding_deposit_cents" => 12_500,
               "destination_outstanding_deposit_cents" => 8_200,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      source = fetched_group(conn, "group-81")
      # The payment filled room-a (9_000) then room-b (3_000); the transfer
      # draws the most recently created allocation first, so room-b's 3_000
      # leaves first and then 2_000 of room-a's cash.
      assert room(source, "room-a")["cash_paid_cents"] == 7_000
      assert room(source, "room-b")["cash_paid_cents"] == 0
      assert source["deposit_paid_cents"] == 7_000
      assert source["outstanding_deposit_cents"] == 12_500
      assert source["revision"] == 3

      destination = fetched_group(conn, "group-92")
      # The destination fills in its original room order.
      assert room(destination, "room-c")["cash_paid_cents"] == 5_000
      assert room(destination, "room-d")["cash_paid_cents"] == 0
      assert destination["deposit_paid_cents"] == 5_000
      assert destination["outstanding_deposit_cents"] == 8_200
      assert destination["revision"] == 2

      # A transfer changes no ledger total.
      assert ledger(conn) == %{
               "cash_held_cents" => 12_000,
               "cash_refunded_cents" => 0,
               "cash_retained_cents" => 0,
               "cash_converted_to_credit_cents" => 0,
               "cash_reduced_cents" => 0,
               "cash_charged_back_cents" => 0,
               "credit_liability_cents" => 0,
               "credit_shortfall_cents" => 0
             }
    end

    test "draws in reverse allocation order regardless of funding kind and fills preserving the draw order",
         %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000)
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [second_open_op()])
      assert [_] = run(conn, [payment_op(%{"amount_cents" => 10_000})])
      assert [_] = run(conn, [credit_op(%{"amount_cents" => 1_500})])

      assert [result] = run(conn, [transfer_op(%{"amount_cents" => 2_000})])
      assert result["status"] == "applied"

      source = fetched_group(conn, "group-81")
      # The credit (allocated last) is drawn first, then 500 of room-b's
      # cash; room-a's earlier cash is untouched.
      assert room(source, "room-a")["cash_paid_cents"] == 9_000
      assert room(source, "room-b")["cash_paid_cents"] == 500
      assert room(source, "room-b")["credit_paid_cents"] == 0
      assert source["deposit_paid_cents"] == 9_500
      assert source["credit_paid_cents"] == 0

      destination = fetched_group(conn, "group-92")
      # The units fill room-c in the order they were drawn: credit first,
      # then cash.
      assert room(destination, "room-c")["credit_paid_cents"] == 1_500
      assert room(destination, "room-c")["cash_paid_cents"] == 500
      assert destination["deposit_paid_cents"] == 2_000
      assert destination["credit_paid_cents"] == 1_500

      # The moved credit remains applied with expiry paused: the liability is
      # unchanged.
      assert guest_credit(conn)["available_cents"] == 700
      assert ledger(conn)["credit_liability_cents"] == 2_200
      assert ledger(conn)["cash_held_cents"] == 10_000
    end

    test "transferred cash settles under the destination group's cancellation policy", %{
      conn: conn
    } do
      open_pair(conn, 5_000)
      assert [_] = run(conn, [transfer_op()])

      # After the transfer the source holds nothing, so cancelling it
      # settles nothing.
      assert [settled] =
               run(conn, [
                 cancel_op(%{"operation_id" => "op-cancel-81", "group_id" => "group-81"})
               ])

      assert settled["status"] == "applied"
      assert settled["refunded_cents"] == 0
      assert settled["retained_cents"] == 0

      # The destination's cash is retained under its own non-refundable date.
      assert [result] =
               run(conn, [
                 cancel_op(%{"operation_id" => "op-cancel-92", "occurred_on" => "2026-12-01"})
               ])

      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5_000
      assert ledger(conn)["cash_retained_cents"] == 5_000
    end

    test "transferred cash converted to hotel credit earns the bonus where it settles", %{
      conn: conn
    } do
      open_pair(conn, 5_000)
      assert [_] = run(conn, [transfer_op()])

      assert [result] =
               run(conn, [cancel_op(%{"refund_method" => "hotel_credit"})])

      assert result["status"] == "applied"
      assert result["credit_issued_cents"] == 5_500
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 0

      assert guest_credit(conn)["available_cents"] == 5_500
      assert ledger(conn)["cash_converted_to_credit_cents"] == 5_000
    end

    test "transferred hotel credit restores to its original lot without another bonus", %{
      conn: conn
    } do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000)
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [second_open_op()])
      assert [_] = run(conn, [credit_op(%{"amount_cents" => 1_500})])

      assert [result] = run(conn, [transfer_op(%{"amount_cents" => 1_500})])
      assert result["status"] == "applied"

      assert [settled] = run(conn, [cancel_op()])

      assert settled["status"] == "applied"
      assert settled["refunded_cents"] == 0
      assert settled["retained_cents"] == 0
      assert settled["credit_issued_cents"] == 0

      # The credit returned to its original lot and original expiry.
      assert guest_credit(conn)["available_cents"] == 2_200

      lots = guest_credit(conn)["lots"]
      assert [%{"source_operation_id" => "op-cancel-fund", "remaining_cents" => 2_200}] = lots

      assert ledger(conn)["credit_liability_cents"] == 2_200
    end

    test "transferred hotel credit is consumed by a non-refundable settlement", %{conn: conn} do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 2_000)
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [second_open_op()])
      assert [_] = run(conn, [credit_op(%{"amount_cents" => 1_500})])
      assert [_] = run(conn, [transfer_op(%{"amount_cents" => 1_500})])

      assert [settled] = run(conn, [cancel_op(%{"occurred_on" => "2026-12-01"})])
      assert settled["status"] == "applied"
      assert settled["retained_cents"] == 0

      assert guest_credit(conn)["available_cents"] == 700
      assert ledger(conn)["credit_liability_cents"] == 700
    end

    test "transferred credit returning to a shortfalled lot extinguishes the clawback", %{
      conn: conn
    } do
      assert [_, _, _] = issue_credit(conn, "op-cancel-fund", "group-fund", 5_000)
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [second_open_op()])
      assert [_] = run(conn, [credit_op(%{"amount_cents" => 5_500})])

      assert [_] =
               run(conn, [
                 chargeback_op(%{
                   "operation_id" => "op-cb-fund",
                   "payment_operation_id" => "op-cancel-fund-pay"
                 })
               ])

      assert ledger(conn)["credit_shortfall_cents"] == 5_500

      assert [moved] = run(conn, [transfer_op(%{"amount_cents" => 5_500})])
      assert moved["status"] == "applied"

      # The shortfall still applies while the credit funds the destination.
      assert ledger(conn)["credit_shortfall_cents"] == 5_500
      assert ledger(conn)["credit_liability_cents"] == 5_500

      assert [settled] = run(conn, [cancel_op()])
      assert settled["status"] == "applied"
      assert settled["refunded_cents"] == 0

      assert guest_credit(conn)["available_cents"] == 0
      assert ledger(conn)["credit_shortfall_cents"] == 0
      assert ledger(conn)["credit_liability_cents"] == 0
    end

    test "rejects same-group and cross-guest transfers", %{conn: conn} do
      open_pair(conn, 5_000)

      assert [_] =
               run(conn, [
                 open_op(%{
                   "operation_id" => "op-open-other",
                   "group_id" => "group-other",
                   "guest_id" => "guest-other"
                 })
               ])

      assert [result] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-same",
                   "destination_group_id" => "group-81"
                 })
               ])

      assert result == %{
               "operation_id" => "op-transfer-same",
               "status" => "rejected",
               "code" => "invalid_transfer"
             }

      assert [result] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-guest",
                   "destination_group_id" => "group-other"
                 })
               ])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_transfer"

      assert fetched_group(conn, "group-81")["revision"] == 2
      assert fetched_group(conn, "group-92")["revision"] == 1
      assert ledger(conn)["cash_held_cents"] == 5_000
    end

    test "rejects inactive groups with that group's group_id", %{conn: conn} do
      open_pair(conn, 5_000)

      assert [_] =
               run(conn, [
                 cancel_op(%{
                   "operation_id" => "op-cancel-81",
                   "group_id" => "group-81",
                   "occurred_on" => "2026-12-01"
                 })
               ])

      assert [result] = run(conn, [transfer_op(%{"operation_id" => "op-transfer-source"})])

      assert result == %{
               "operation_id" => "op-transfer-source",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-81"
             }

      assert [_] =
               run(conn, [
                 cancel_op(%{"operation_id" => "op-cancel-92", "occurred_on" => "2026-12-01"})
               ])

      assert [result] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-destination",
                   "source_group_id" => "group-92",
                   "destination_group_id" => "group-81"
                 })
               ])

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "group-92"
    end

    test "rejects non-positive amounts", %{conn: conn} do
      open_pair(conn, 5_000)

      for {amount, i} <- Enum.with_index([0, -100]) do
        assert [result] =
                 run(conn, [
                   transfer_op(%{
                     "operation_id" => "op-transfer-bad-#{i}",
                     "amount_cents" => amount
                   })
                 ])

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_amount"
      end

      assert fetched_group(conn, "group-81")["revision"] == 2
      assert fetched_group(conn, "group-92")["revision"] == 1
    end

    test "rejects an amount exceeding the source's held funding", %{conn: conn} do
      open_pair(conn, 5_000)

      assert [result] = run(conn, [transfer_op(%{"amount_cents" => 5_001})])
      assert result["status"] == "rejected"
      assert result["code"] == "transfer_exceeds_held_funding"

      assert fetched_group(conn, "group-81")["deposit_paid_cents"] == 5_000
      assert fetched_group(conn, "group-92")["deposit_paid_cents"] == 0
    end

    test "rejects an amount exceeding the destination's outstanding deposit", %{conn: conn} do
      open_pair(conn, 19_500)

      assert [result] = run(conn, [transfer_op(%{"amount_cents" => 13_201})])
      assert result["status"] == "rejected"
      assert result["code"] == "transfer_exceeds_outstanding"

      # The complete outstanding deposit is valid.
      assert [result] =
               run(conn, [
                 transfer_op(%{"operation_id" => "op-transfer-all", "amount_cents" => 13_200})
               ])

      assert result["status"] == "applied"
      assert result["destination_outstanding_deposit_cents"] == 0
      assert fetched_group(conn, "group-92")["deposit_paid_cents"] == 13_200
    end

    test "resolves source existence, then destination existence", %{conn: conn} do
      assert [_] = run(conn, [open_op()])

      assert [result] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-no-source",
                   "source_group_id" => "group-missing",
                   "destination_group_id" => "group-missing-too"
                 })
               ])

      assert result == %{
               "operation_id" => "op-transfer-no-source",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "group-missing"
             }

      assert [result] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-no-destination",
                   "destination_group_id" => "group-missing"
                 })
               ])

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "group-missing"
    end

    test "checks the source revision and then the destination revision before the transfer rules",
         %{conn: conn} do
      open_pair(conn, 5_000)

      # A stale source revision is rejected before the destination revision
      # and before the transfer rules, even for a same-group transfer.
      assert [result] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-stale-both",
                   "destination_group_id" => "group-81",
                   "expected_revision" => 9,
                   "destination_expected_revision" => 9
                 })
               ])

      assert result == %{
               "operation_id" => "op-transfer-stale-both",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 9,
               "actual_revision" => 2
             }

      assert [result] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-stale-destination",
                   "expected_revision" => 2,
                   "destination_expected_revision" => 9
                 })
               ])

      assert result == %{
               "operation_id" => "op-transfer-stale-destination",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-92",
               "expected_revision" => 9,
               "actual_revision" => 1
             }

      # Existence resolves before any revision check.
      assert [result] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-stale-missing",
                   "destination_group_id" => "group-missing",
                   "expected_revision" => 9
                 })
               ])

      assert result["code"] == "group_not_found"

      assert [result] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-match",
                   "expected_revision" => 2,
                   "destination_expected_revision" => 1
                 })
               ])

      assert result["status"] == "applied"
      assert result["source_revision"] == 3
      assert result["destination_revision"] == 2

      # Rejections never increment either revision.
      assert fetched_group(conn, "group-81")["revision"] == 3
      assert fetched_group(conn, "group-92")["revision"] == 2
    end

    test "rejects operations missing data needed to identify and apply them", %{conn: conn} do
      open_pair(conn, 5_000)

      for {overrides, i} <-
            Enum.with_index([
              %{"source_group_id" => nil},
              %{"destination_group_id" => nil},
              %{"amount_cents" => nil},
              %{"source_group_id" => ""}
            ]) do
        operation =
          %{
            "operation_id" => "op-transfer-incomplete-#{i}",
            "type" => "transfer_deposit",
            "occurred_on" => "2026-10-05",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-92",
            "amount_cents" => 1_000
          }
          |> Map.merge(overrides)

        assert [result] = run(conn, [operation])
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end

      assert [result] =
               run(conn, [
                 %{
                   "operation_id" => "op-transfer-no-date",
                   "type" => "transfer_deposit",
                   "source_group_id" => "group-81",
                   "destination_group_id" => "group-92",
                   "amount_cents" => 1_000
                 }
               ])

      assert result["code"] == "invalid_operation"

      assert fetched_group(conn, "group-81")["revision"] == 2
      assert fetched_group(conn, "group-92")["revision"] == 1
    end

    test "is durably idempotent", %{conn: conn} do
      open_pair(conn, 12_000)

      operation = transfer_op()
      assert [first] = run(conn, [operation])
      assert first["status"] == "applied"

      # A retry returns the exact stored result without moving funding again.
      assert [retry] = run(conn, [operation])
      assert retry == first

      assert fetched_group(conn, "group-81")["deposit_paid_cents"] == 7_000
      assert fetched_group(conn, "group-81")["revision"] == 3
      assert fetched_group(conn, "group-92")["deposit_paid_cents"] == 5_000
      assert fetched_group(conn, "group-92")["revision"] == 2
      assert ledger(conn)["cash_held_cents"] == 12_000

      stored =
        conn
        |> get("/api/v1/operations/op-transfer")
        |> json_response(200)
        |> Map.fetch!("data")

      assert stored == first

      # Reusing the identifier with a different payload is a conflict.
      assert [conflict] = run(conn, [transfer_op(%{"amount_cents" => 4_999})])
      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"
    end

    test "observes changes made by earlier operations in the same batch", %{conn: conn} do
      assert [opened, second, paid, transferred] =
               run(conn, [
                 open_op(),
                 second_open_op(),
                 payment_op(%{"amount_cents" => 8_000}),
                 transfer_op(%{"amount_cents" => 8_000})
               ])

      assert opened["status"] == "applied"
      assert second["status"] == "applied"
      assert paid["status"] == "applied"
      assert transferred["status"] == "applied"
      assert transferred["source_revision"] == 3
      assert transferred["destination_revision"] == 2
      assert transferred["source_outstanding_deposit_cents"] == 19_500
      assert transferred["destination_outstanding_deposit_cents"] == 5_200

      assert fetched_group(conn, "group-92")["deposit_paid_cents"] == 8_000
    end

    test "transferred funding can be transferred again", %{conn: conn} do
      open_pair(conn, 12_000)

      assert [_] =
               run(conn, [
                 transfer_op(%{"operation_id" => "op-transfer-1", "amount_cents" => 5_000})
               ])

      assert [result] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-2",
                   "source_group_id" => "group-92",
                   "destination_group_id" => "group-81",
                   "amount_cents" => 3_000
                 })
               ])

      assert result["status"] == "applied"
      assert result["source_outstanding_deposit_cents"] == 11_200
      assert result["destination_outstanding_deposit_cents"] == 9_500
      assert result["source_revision"] == 3
      assert result["destination_revision"] == 4

      source = fetched_group(conn, "group-81")
      # The returning cash continues filling room-a, then room-b.
      assert room(source, "room-a")["cash_paid_cents"] == 9_000
      assert room(source, "room-b")["cash_paid_cents"] == 1_000
      assert source["deposit_paid_cents"] == 10_000

      destination = fetched_group(conn, "group-92")
      assert room(destination, "room-c")["cash_paid_cents"] == 2_000
      assert destination["deposit_paid_cents"] == 2_000

      assert ledger(conn)["cash_held_cents"] == 12_000

      assert statement(conn, "op-pay")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 10_000},
               %{"group_id" => "group-92", "amount_cents" => 2_000}
             ]
    end

    test "moves legacy unattributed funding with its provenance", %{conn: conn} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      group_id = "group-legacy"

      Repo.insert!(%GroupStay.Groups.Group{
        group_id: group_id,
        guest_id: "guest-legacy",
        property_id: "ams-canal",
        booked_on: ~D[2026-06-01],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-11],
        rate_plan: "flexible",
        lodging_total_cents: 20_000,
        deposit_due_cents: 4_000,
        deposit_paid_cents: 1_600,
        credit_paid_cents: 600,
        inserted_at: now,
        updated_at: now
      })

      for {room_id, position} <- Enum.with_index(~w(room-1 room-2 room-3 room-4)) do
        Repo.insert!(%GroupStay.Groups.Room{
          group_id: group_id,
          room_id: room_id,
          nightly_rate_cents: 5_000,
          position: position,
          inserted_at: now,
          updated_at: now
        })
      end

      lot =
        Repo.insert!(%GroupStay.Credit.Lot{
          guest_id: "guest-legacy",
          source_operation_id: "cancel-legacy",
          issued_cents: 1_100,
          remaining_cents: 500,
          expires_on: ~D[2027-10-21],
          inserted_at: now,
          updated_at: now
        })

      Repo.insert!(%GroupStay.Credit.Application{
        group_id: group_id,
        lot_id: lot.id,
        amount_cents: 600,
        inserted_at: now,
        updated_at: now
      })

      assert [_] =
               run(conn, [
                 open_op(%{
                   "operation_id" => "op-open-legacy-dest",
                   "group_id" => "group-legacy-dest",
                   "guest_id" => "guest-legacy"
                 })
               ])

      assert [result] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-legacy",
                   "source_group_id" => group_id,
                   "destination_group_id" => "group-legacy-dest",
                   "amount_cents" => 1_200
                 })
               ])

      assert result["status"] == "applied"

      # The senior block's credit (allocated after its cash) is drawn first.
      source = fetched_group(conn, group_id)
      assert room(source, "room-1")["cash_paid_cents"] == 400
      assert room(source, "room-1")["credit_paid_cents"] == 0
      assert room(source, "room-2")["credit_paid_cents"] == 0
      assert source["deposit_paid_cents"] == 400
      assert source["credit_paid_cents"] == 0

      destination = fetched_group(conn, "group-legacy-dest")
      assert room(destination, "room-a")["credit_paid_cents"] == 600
      assert room(destination, "room-a")["cash_paid_cents"] == 600
      assert destination["deposit_paid_cents"] == 1_200
      assert destination["credit_paid_cents"] == 600

      # No aggregate balance changes.
      assert ledger(conn)["cash_held_cents"] == 1_000
      assert ledger(conn)["credit_liability_cents"] == 1_100
      assert guest_credit(conn, "guest-legacy")["available_cents"] == 500

      # A refundable settlement of the destination restores the legacy credit
      # to its original lot and refunds the legacy cash.
      assert [settled] =
               run(conn, [
                 cancel_op(%{
                   "operation_id" => "op-cancel-legacy-dest",
                   "group_id" => "group-legacy-dest",
                   "occurred_on" => "2026-11-26"
                 })
               ])

      assert settled["status"] == "applied"
      assert settled["refunded_cents"] == 600
      assert settled["credit_issued_cents"] == 0
      assert guest_credit(conn, "guest-legacy")["available_cents"] == 1_100
    end
  end

  describe "reductions and chargebacks across groups" do
    test "reduce_cash_payment removes held cash in reverse allocation order across groups", %{
      conn: conn
    } do
      open_pair(conn, 12_000)
      assert [_] = run(conn, [transfer_op(%{"amount_cents" => 4_000})])

      assert [result] = run(conn, [reduce_op(%{"amount_cents" => 5_000})])

      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "amount_cents" => 5_000,
               "outstanding_deposit_cents" => 12_500,
               "revision" => 4
             }

      # The transferred cash (allocated most recently) is removed first, from
      # the destination, and then the source's room-a loses 1_000.
      source = fetched_group(conn, "group-81")
      assert room(source, "room-a")["cash_paid_cents"] == 7_000
      assert room(source, "room-b")["cash_paid_cents"] == 0
      assert source["deposit_paid_cents"] == 7_000
      assert source["revision"] == 4

      destination = fetched_group(conn, "group-92")
      assert room(destination, "room-c")["cash_paid_cents"] == 0
      assert destination["deposit_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 13_200
      assert destination["revision"] == 3

      assert ledger(conn)["cash_held_cents"] == 7_000
      assert ledger(conn)["cash_reduced_cents"] == 5_000

      assert statement(conn, "op-pay")["held_cents"] == 7_000
      assert statement(conn, "op-pay")["reduced_cents"] == 5_000
    end

    test "a reduction increments the addressed group even when it holds none of the payment", %{
      conn: conn
    } do
      open_pair(conn, 5_000)
      assert [_] = run(conn, [transfer_op()])

      assert [result] = run(conn, [reduce_op(%{"amount_cents" => 5_000})])
      assert result["status"] == "applied"
      assert result["group_id"] == "group-81"
      assert result["revision"] == 4
      assert result["outstanding_deposit_cents"] == 19_500

      assert fetched_group(conn, "group-81")["revision"] == 4
      assert fetched_group(conn, "group-92")["revision"] == 3
      assert fetched_group(conn, "group-92")["outstanding_deposit_cents"] == 13_200
    end

    test "charge_back_payment reclassifies held cash wherever it currently funds rooms", %{
      conn: conn
    } do
      open_pair(conn, 12_000)
      assert [_] = run(conn, [transfer_op(%{"amount_cents" => 4_000})])

      assert [result] = run(conn, [chargeback_op()])

      assert result == %{
               "operation_id" => "op-chargeback",
               "status" => "applied",
               "payment_operation_id" => "op-pay",
               "group_id" => "group-81",
               "charged_back_cents" => 12_000,
               "outstanding_deposit_cents" => 19_500,
               "revision" => 4
             }

      assert fetched_group(conn, "group-81")["deposit_paid_cents"] == 0
      assert fetched_group(conn, "group-81")["revision"] == 4
      assert fetched_group(conn, "group-92")["deposit_paid_cents"] == 0
      assert fetched_group(conn, "group-92")["outstanding_deposit_cents"] == 13_200
      assert fetched_group(conn, "group-92")["revision"] == 3

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 12_000

      assert statement(conn, "op-pay")["held_cents"] == 0
      assert statement(conn, "op-pay")["charged_back_cents"] == 12_000
    end

    test "a chargeback adjusts the settlement counters of the group that settled the cash", %{
      conn: conn
    } do
      open_pair(conn, 5_000)
      assert [_] = run(conn, [transfer_op()])

      # The transferred cash settles under the destination group.
      assert [settled] = run(conn, [cancel_op()])
      assert settled["status"] == "applied"
      assert settled["refunded_cents"] == 5_000

      assert [result] = run(conn, [chargeback_op()])

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 5_000
      assert result["group_id"] == "group-81"
      # The single revision in the result is the addressed group's.
      assert result["revision"] == 4
      assert result["outstanding_deposit_cents"] == 19_500

      assert fetched_group(conn, "group-81")["revision"] == 4
      assert fetched_group(conn, "group-92")["revision"] == 4

      assert ledger(conn)["cash_refunded_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 5_000
    end

    test "never rewrites the original payment's stored result", %{conn: conn} do
      assert [_] = run(conn, [open_op()])
      assert [_] = run(conn, [second_open_op()])
      assert [paid] = run(conn, [payment_op(%{"amount_cents" => 12_000})])
      assert [_] = run(conn, [transfer_op(%{"amount_cents" => 4_000})])
      assert [_] = run(conn, [chargeback_op()])

      # Retrying the original payment returns its exact original result
      # without reapplying cash, even though the funding moved groups.
      assert [retry] = run(conn, [payment_op(%{"amount_cents" => 12_000})])
      assert retry == paid

      assert ledger(conn)["cash_charged_back_cents"] == 12_000
      assert ledger(conn)["cash_held_cents"] == 0
    end
  end

  describe "payment statement evolution" do
    test "adds held_by_group once funding from the payment has participated in a transfer", %{
      conn: conn
    } do
      open_pair(conn, 10_000)

      # Before any transfer the statement keeps its earlier shape.
      refute Map.has_key?(statement(conn, "op-pay"), "held_by_group")

      assert [_] = run(conn, [transfer_op(%{"amount_cents" => 4_000})])

      data = statement(conn, "op-pay")

      assert data["held_cents"] == 10_000

      assert data["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 6_000},
               %{"group_id" => "group-92", "amount_cents" => 4_000}
             ]

      # The amounts sum to held_cents.
      assert data["held_by_group"] |> Enum.map(& &1["amount_cents"]) |> Enum.sum() ==
               data["held_cents"]

      # A payment that has never participated keeps the earlier shape.
      assert [_] =
               run(conn, [payment_op(%{"operation_id" => "op-pay-2", "amount_cents" => 1_000})])

      refute Map.has_key?(statement(conn, "op-pay-2"), "held_by_group")
    end

    test "orders held_by_group by group_id and omits groups with no held cash", %{conn: conn} do
      assert [_] =
               run(conn, [
                 open_op(%{"operation_id" => "op-open-z", "group_id" => "group-z"})
               ])

      assert [_] =
               run(conn, [
                 open_op(%{"operation_id" => "op-open-a", "group_id" => "group-a"})
               ])

      assert [_] =
               run(conn, [
                 payment_op(%{
                   "operation_id" => "op-pay-z",
                   "group_id" => "group-z",
                   "amount_cents" => 10_000
                 })
               ])

      assert [_] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-z",
                   "source_group_id" => "group-z",
                   "destination_group_id" => "group-a",
                   "amount_cents" => 4_000
                 })
               ])

      data = statement(conn, "op-pay-z")

      assert data["held_by_group"] == [
               %{"group_id" => "group-a", "amount_cents" => 4_000},
               %{"group_id" => "group-z", "amount_cents" => 6_000}
             ]

      # Moving the remainder across leaves only one group holding cash.
      assert [_] =
               run(conn, [
                 transfer_op(%{
                   "operation_id" => "op-transfer-z2",
                   "source_group_id" => "group-z",
                   "destination_group_id" => "group-a",
                   "amount_cents" => 6_000
                 })
               ])

      assert statement(conn, "op-pay-z")["held_by_group"] == [
               %{"group_id" => "group-a", "amount_cents" => 10_000}
             ]
    end

    test "returns an empty list after no held cash remains", %{conn: conn} do
      open_pair(conn, 5_000)
      assert [_] = run(conn, [transfer_op()])
      assert [_] = run(conn, [chargeback_op()])

      data = statement(conn, "op-pay")
      assert data["held_cents"] == 0
      assert data["held_by_group"] == []
      assert data["charged_back_cents"] == 5_000
    end

    test "all earlier statement fields retain their meaning after a transfer", %{conn: conn} do
      open_pair(conn, 12_000)
      assert [_] = run(conn, [transfer_op(%{"amount_cents" => 4_000})])

      assert [_] =
               run(conn, [
                 cancel_op(%{
                   "operation_id" => "op-cancel-92",
                   "occurred_on" => "2026-12-01"
                 })
               ])

      assert [_] = run(conn, [reduce_op(%{"amount_cents" => 1_000})])

      data = statement(conn, "op-pay")

      assert data == %{
               "payment_operation_id" => "op-pay",
               "original_group_id" => "group-81",
               "recorded_cents" => 12_000,
               "held_cents" => 7_000,
               "refunded_cents" => 0,
               "retained_cents" => 4_000,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 1_000,
               "charged_back_cents" => 0,
               "held_by_group" => [
                 %{"group_id" => "group-81", "amount_cents" => 7_000}
               ]
             }
    end
  end
end
