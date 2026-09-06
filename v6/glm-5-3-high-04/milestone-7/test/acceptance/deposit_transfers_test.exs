defmodule GroupStayWeb.DepositTransfersTest do
  @moduledoc """
  Acceptance tests for the deposit-transfer release: moving held funding
  between two active groups of the same guest, the revisions such an
  operation increments across groups, reductions and chargebacks that follow
  a payment's allocations wherever they currently fund rooms, and the
  `held_by_group` evolution of the payment statement.
  """

  use GroupStayWeb.ConnCase, async: false

  alias GroupStay.Credit.Application, as: CreditApplication
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @batch_url "/api/v1/partner-batches"

  defp post_batch(conn, operations) do
    post(conn, @batch_url, %{"operations" => operations})
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp open_group_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-open"),
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

  defp payment_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-pay"),
        "type" => "record_cash_payment",
        "occurred_on" => "2026-10-04",
        "group_id" => "group-81",
        "amount_cents" => 9_500
      },
      overrides
    )
  end

  defp cancel_group_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-cancel"),
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => "group-81"
      },
      overrides
    )
  end

  defp apply_credit_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-credit"),
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-12-01",
        "group_id" => "group-81",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp reduce_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-reduce"),
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-10",
        "payment_operation_id" => "op-pay-1",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp charge_back_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-charge"),
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-10",
        "payment_operation_id" => "op-pay-1"
      },
      overrides
    )
  end

  defp transfer_operation(overrides) do
    Map.merge(
      %{
        "operation_id" => unique_id("op-transfer"),
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-05",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-82",
        "amount_cents" => 1_000
      },
      overrides
    )
  end

  defp apply_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "applied", "expected applied, got: #{inspect(result)}"
    result
  end

  defp reject_operation!(conn, operation) do
    conn = post_batch(conn, [operation])
    assert %{"results" => [result]} = json_response(conn, 200)
    assert result["status"] == "rejected", "expected rejected, got: #{inspect(result)}"
    result
  end

  defp open_group!(conn, overrides \\ %{}) do
    apply_operation!(conn, open_group_operation(overrides))
  end

  # group-82 is a one-room group of the same guest whose deposit is 60000.
  defp open_destination!(conn, overrides \\ %{}) do
    open_group!(
      conn,
      Map.merge(
        %{
          "group_id" => "group-82",
          "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 100_000}]
        },
        overrides
      )
    )
  end

  defp fetch_group(conn, group_id) do
    conn = get(conn, "/api/v1/groups/#{group_id}")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp room_view(group, room_id) do
    Enum.find(group["rooms"], &(&1["room_id"] == room_id))
  end

  defp ledger(conn) do
    conn = get(conn, "/api/v1/ledger")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp guest_credit(conn, guest_id) do
    conn = get(conn, "/api/v1/guests/#{guest_id}/credit")
    assert conn.status == 200
    %{"data" => data} = json_response(conn, 200)
    data
  end

  defp payment_statement!(conn, operation_id) do
    conn = get(conn, "/api/v1/payments/#{operation_id}")
    assert conn.status == 200, "expected 200, got: #{conn.status}"
    %{"data" => data} = json_response(conn, 200)
    data
  end

  # group-81 (room deposits 9000 and 10500) with op-pay-1 holding 9000 on
  # room-a and op-pay-2 holding 1000 on room-b.
  defp funded_source!(conn) do
    open_group!(conn)

    apply_operation!(
      conn,
      payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9_000})
    )

    apply_operation!(
      conn,
      payment_operation(%{"operation_id" => "op-pay-2", "amount_cents" => 1_000})
    )
  end

  # Issues one hotel-credit lot worth amount * 1.1 to guest-22 by refundably
  # cancelling a funded helper group with the hotel_credit refund method.
  # The funding payment is recorded as "op-pay-fund" so a test can charge it
  # back and claw back the entitlement it created.
  defp issue_credit!(conn, amount_cents) do
    open_group!(
      conn,
      %{
        "group_id" => "group-fund",
        "rooms" => [%{"room_id" => "room-c", "nightly_rate_cents" => 100_000}]
      }
    )

    apply_operation!(
      conn,
      payment_operation(%{
        "operation_id" => "op-pay-fund",
        "group_id" => "group-fund",
        "amount_cents" => amount_cents
      })
    )

    apply_operation!(
      conn,
      cancel_group_operation(%{
        "group_id" => "group-fund",
        "refund_method" => "hotel_credit"
      })
    )
  end

  describe "moving held funding" do
    test "moves cash in reverse allocation order with provenance", %{conn: conn} do
      funded_source!(conn)
      open_destination!(conn)

      result = apply_operation!(conn, transfer_operation(%{"amount_cents" => 1_500}))

      assert result == %{
               "operation_id" => result["operation_id"],
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-82",
               "amount_cents" => 1_500,
               "source_outstanding_deposit_cents" => 11_000,
               "destination_outstanding_deposit_cents" => 58_500,
               "source_revision" => 4,
               "destination_revision" => 2
             }

      source = fetch_group(conn, "group-81")

      # The most recent allocation (op-pay-2 on room-b) is drawn first, then
      # the remainder from op-pay-1 on room-a.
      assert source["revision"] == 4
      assert source["deposit_paid_cents"] == 8_500
      assert source["outstanding_deposit_cents"] == 11_000
      assert room_view(source, "room-a")["cash_paid_cents"] == 8_500
      assert room_view(source, "room-b")["cash_paid_cents"] == 0

      destination = fetch_group(conn, "group-82")

      assert destination["revision"] == 2
      assert destination["deposit_paid_cents"] == 1_500
      assert destination["outstanding_deposit_cents"] == 58_500
      assert room_view(destination, "room-x")["cash_paid_cents"] == 1_500

      # Each moved allocation keeps its payment identity.
      assert payment_statement!(conn, "op-pay-1")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 8_500},
               %{"group_id" => "group-82", "amount_cents" => 500}
             ]

      assert payment_statement!(conn, "op-pay-2")["held_by_group"] == [
               %{"group_id" => "group-82", "amount_cents" => 1_000}
             ]

      # A transfer changes no ledger total.
      assert ledger(conn)["cash_held_cents"] == 10_000
      assert ledger(conn)["cash_refunded_cents"] == 0
      assert ledger(conn)["cash_retained_cents"] == 0
      assert ledger(conn)["cash_converted_to_credit_cents"] == 0
      assert ledger(conn)["cash_reduced_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 0
    end

    test "draws mixed funding regardless of kind and fills in draw order", %{conn: conn} do
      issue_credit!(conn, 5_000)

      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9_000})
      )

      apply_operation!(
        conn,
        apply_credit_operation(%{"amount_cents" => 1_000})
      )

      open_destination!(conn)

      before_ledger = ledger(conn)
      before_credit = guest_credit(conn, "guest-22")

      result = apply_operation!(conn, transfer_operation(%{"amount_cents" => 1_500}))

      assert result["source_revision"] == 4
      assert result["destination_revision"] == 2

      source = fetch_group(conn, "group-81")

      # The credit application is the most recent allocation and is drawn
      # first; the remainder comes from op-pay-1's cash.
      assert room_view(source, "room-a")["cash_paid_cents"] == 8_500
      assert room_view(source, "room-b")["credit_paid_cents"] == 0
      assert source["deposit_paid_cents"] == 8_500
      assert source["outstanding_deposit_cents"] == 11_000

      destination = fetch_group(conn, "group-82")

      # The drawn units fill the destination's first room in draw order.
      assert room_view(destination, "room-x")["credit_paid_cents"] == 1_000
      assert room_view(destination, "room-x")["cash_paid_cents"] == 500

      # Transferred credit stays applied with its expiry paused: the lot is
      # untouched and no liability or availability changes.
      assert guest_credit(conn, "guest-22") == before_credit
      assert ledger(conn) == before_ledger

      assert payment_statement!(conn, "op-pay-1")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 8_500},
               %{"group_id" => "group-82", "amount_cents" => 500}
             ]
    end

    test "splits drawn units across the destination's rooms in order", %{conn: conn} do
      funded_source!(conn)

      # Deposits of 300 and 1500: the destination's outstanding is 1800.
      open_group!(
        conn,
        %{
          "group_id" => "group-82",
          "rooms" => [
            %{"room_id" => "room-x", "nightly_rate_cents" => 500},
            %{"room_id" => "room-y", "nightly_rate_cents" => 2_500}
          ]
        }
      )

      # Draws op-pay-2's 1000 first, then 200 of op-pay-1; room-x's 300
      # capacity is filled by op-pay-2 and the rest lands on room-y.
      apply_operation!(conn, transfer_operation(%{"amount_cents" => 1_200}))

      destination = fetch_group(conn, "group-82")

      assert room_view(destination, "room-x")["cash_paid_cents"] == 300
      assert room_view(destination, "room-y")["cash_paid_cents"] == 900
    end

    test "brings pre-accounting funding forward when transferring", %{conn: conn} do
      insert_pre_accounting_funded_group!()
      open_destination!(conn)

      result = apply_operation!(conn, transfer_operation(%{"amount_cents" => 2_000}))

      assert result["source_outstanding_deposit_cents"] == 16_500
      assert result["destination_outstanding_deposit_cents"] == 58_000
      assert result["source_revision"] == 3
      assert result["destination_revision"] == 2

      source = fetch_group(conn, "group-81")
      assert room_view(source, "room-a")["cash_paid_cents"] == 3_000

      assert payment_statement!(conn, "op-pay-1")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 3_000},
               %{"group_id" => "group-82", "amount_cents" => 2_000}
             ]
    end

    test "materialized funding keeps its operation-processing order", %{conn: conn} do
      issue_credit!(conn, 5_000)
      insert_pre_accounting_mixed_group!()
      open_destination!(conn)

      # The group was funded with credit first and the durable cash payment
      # afterward, so the payment's allocations are the most recent and are
      # drawn first.
      apply_operation!(conn, transfer_operation(%{"amount_cents" => 1_500}))

      destination = fetch_group(conn, "group-82")
      assert room_view(destination, "room-x")["cash_paid_cents"] == 1_500
      assert room_view(destination, "room-x")["credit_paid_cents"] == 0

      source = fetch_group(conn, "group-81")
      assert room_view(source, "room-a")["cash_paid_cents"] == 3_500
      assert room_view(source, "room-a")["credit_paid_cents"] == 1_000

      assert payment_statement!(conn, "op-pay-1")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 3_500},
               %{"group_id" => "group-82", "amount_cents" => 1_500}
             ]

      # The credit keeps funding the source group's room.
      assert guest_credit(conn, "guest-22")["available_cents"] == 4_500
    end

    test "transfers the complete held funding", %{conn: conn} do
      funded_source!(conn)
      open_destination!(conn)

      result = apply_operation!(conn, transfer_operation(%{"amount_cents" => 10_000}))

      assert result["source_outstanding_deposit_cents"] == 19_500
      assert result["destination_outstanding_deposit_cents"] == 50_000

      source = fetch_group(conn, "group-81")
      assert source["deposit_paid_cents"] == 0
      assert source["outstanding_deposit_cents"] == 19_500

      # Every group holding cash of either payment is the destination.
      assert payment_statement!(conn, "op-pay-1")["held_by_group"] == [
               %{"group_id" => "group-82", "amount_cents" => 9_000}
             ]

      assert payment_statement!(conn, "op-pay-2")["held_by_group"] == [
               %{"group_id" => "group-82", "amount_cents" => 1_000}
             ]
    end

    test "is durably idempotent", %{conn: conn} do
      funded_source!(conn)
      open_destination!(conn)

      op = transfer_operation(%{"operation_id" => "op-transfer-1", "amount_cents" => 1_500})
      original = apply_operation!(conn, op)

      conn
      |> post_batch([op])
      |> json_response(200)
      |> then(fn %{"results" => [retried]} -> assert retried == original end)

      # The retry does not move funding again.
      assert fetch_group(conn, "group-81")["revision"] == 4
      assert fetch_group(conn, "group-82")["revision"] == 2
      assert fetch_group(conn, "group-82")["deposit_paid_cents"] == 1_500
      assert ledger(conn)["cash_held_cents"] == 10_000
    end

    test "observes earlier operations of the same batch", %{conn: conn} do
      funded_source!(conn)
      open_destination!(conn)

      first = transfer_operation(%{"amount_cents" => 1_500})

      second =
        transfer_operation(%{
          "amount_cents" => 500,
          "expected_revision" => 4,
          "destination_expected_revision" => 2
        })

      conn
      |> post_batch([first, second])
      |> json_response(200)
      |> then(fn %{"results" => [first_result, second_result]} ->
        assert first_result["status"] == "applied"
        assert second_result["status"] == "applied"
        assert second_result["source_revision"] == 5
        assert second_result["destination_revision"] == 3
      end)

      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 8_000
      assert fetch_group(conn, "group-82")["deposit_paid_cents"] == 2_000
    end
  end

  describe "rejections" do
    test "invalid_transfer for the same group or different guests", %{conn: conn} do
      funded_source!(conn)

      assert reject_operation!(
               conn,
               transfer_operation(%{"destination_group_id" => "group-81"})
             )["code"] == "invalid_transfer"

      open_group!(conn, %{"group_id" => "group-83", "guest_id" => "guest-99"})

      assert reject_operation!(
               conn,
               transfer_operation(%{"destination_group_id" => "group-83"})
             )["code"] == "invalid_transfer"

      # A rejected transfer changes no state.
      assert fetch_group(conn, "group-81")["revision"] == 3
      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 10_000
    end

    test "group_not_found resolves the source first, then the destination", %{conn: conn} do
      open_group!(conn)

      result =
        reject_operation!(
          conn,
          transfer_operation(%{
            "source_group_id" => "group-none",
            "destination_group_id" => "group-82-none"
          })
        )

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "group-none"

      result =
        reject_operation!(
          conn,
          transfer_operation(%{"destination_group_id" => "group-none"})
        )

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "group-none"
    end

    test "group_not_active names the inactive group", %{conn: conn} do
      funded_source!(conn)
      open_destination!(conn)

      apply_operation!(conn, cancel_group_operation(%{"group_id" => "group-81"}))

      result = reject_operation!(conn, transfer_operation(%{}))

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "group-81"

      apply_operation!(conn, cancel_group_operation(%{"group_id" => "group-82"}))

      result = reject_operation!(conn, transfer_operation(%{}))

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "group-81"
    end

    test "a cancelled destination is rejected even when the source is active", %{conn: conn} do
      funded_source!(conn)

      open_destination!(conn)
      apply_operation!(conn, cancel_group_operation(%{"group_id" => "group-82"}))

      result = reject_operation!(conn, transfer_operation(%{}))

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "group-82"
    end

    test "invalid_amount for unusable amounts", %{conn: conn} do
      funded_source!(conn)
      open_destination!(conn)

      for amount <- [0, -100, "500", 1.5, nil] do
        assert reject_operation!(conn, transfer_operation(%{"amount_cents" => amount}))["code"] ==
                 "invalid_amount",
               "for #{inspect(amount)}"
      end
    end

    test "held funding and outstanding deposit limits", %{conn: conn} do
      funded_source!(conn)

      # Held funding is 10000; a larger request is rejected before the
      # destination's outstanding deposit is considered.
      open_destination!(conn)

      assert reject_operation!(
               conn,
               transfer_operation(%{"amount_cents" => 10_001})
             )["code"] == "transfer_exceeds_held_funding"

      # A destination whose outstanding deposit is smaller than the request.
      open_group!(
        conn,
        %{
          "group_id" => "group-84",
          "rooms" => [%{"room_id" => "room-tiny", "nightly_rate_cents" => 1_000}]
        }
      )

      assert reject_operation!(
               conn,
               transfer_operation(%{"destination_group_id" => "group-84", "amount_cents" => 601})
             )["code"] == "transfer_exceeds_outstanding"

      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 10_000
      assert fetch_group(conn, "group-84")["deposit_paid_cents"] == 0
    end

    test "checks the source revision and then the destination revision", %{conn: conn} do
      funded_source!(conn)
      open_destination!(conn)

      # The source is at revision 3 after two payments.
      stale_source =
        transfer_operation(%{"expected_revision" => 2, "amount_cents" => 1_000})

      result = reject_operation!(conn, stale_source)

      assert result == %{
               "operation_id" => stale_source["operation_id"],
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 2,
               "actual_revision" => 3
             }

      stale_destination =
        transfer_operation(%{"destination_expected_revision" => 99, "amount_cents" => 1_000})

      result = reject_operation!(conn, stale_destination)

      assert result == %{
               "operation_id" => stale_destination["operation_id"],
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-82",
               "expected_revision" => 99,
               "actual_revision" => 1
             }

      # Revisions are checked before the transfer rules.
      result =
        reject_operation!(
          conn,
          transfer_operation(%{
            "destination_group_id" => "group-81",
            "expected_revision" => 1
          })
        )

      assert result["code"] == "stale_revision"
      assert result["group_id"] == "group-81"

      assert fetch_group(conn, "group-81")["revision"] == 3
      assert fetch_group(conn, "group-82")["revision"] == 1
    end

    test "an unusable operation is rejected with invalid_operation", %{conn: conn} do
      for overrides <- [
            %{"source_group_id" => nil},
            %{"destination_group_id" => ""},
            Map.delete(transfer_operation(%{}), "source_group_id")
          ] do
        assert reject_operation!(conn, overrides)["code"] == "invalid_operation"
      end
    end
  end

  describe "revisions across groups" do
    test "increments both groups exactly once", %{conn: conn} do
      funded_source!(conn)
      open_destination!(conn)

      apply_operation!(conn, transfer_operation(%{"amount_cents" => 1_500}))

      assert fetch_group(conn, "group-81")["revision"] == 4
      assert fetch_group(conn, "group-82")["revision"] == 2

      # A second transfer composes against the new state.
      apply_operation!(
        conn,
        transfer_operation(%{"amount_cents" => 500, "expected_revision" => 4})
      )

      assert fetch_group(conn, "group-81")["revision"] == 5
      assert fetch_group(conn, "group-82")["revision"] == 3
      assert fetch_group(conn, "group-81")["deposit_paid_cents"] == 8_000
      assert fetch_group(conn, "group-82")["deposit_paid_cents"] == 2_000
    end

    test "a reduction follows a payment's allocations across groups", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9_000})
      )

      open_destination!(conn)

      apply_operation!(conn, transfer_operation(%{"amount_cents" => 4_000}))

      # The allocations moved to group-82 were created last, so the
      # reduction removes them first, then the remainder from group-81.
      result = apply_operation!(conn, reduce_operation(%{"amount_cents" => 6_000}))

      assert result["group_id"] == "group-81"
      assert result["outstanding_deposit_cents"] == 16_500
      assert result["revision"] == 4

      source = fetch_group(conn, "group-81")
      assert source["deposit_paid_cents"] == 3_000
      assert source["outstanding_deposit_cents"] == 16_500
      assert source["revision"] == 4

      # The other group's funding changed, so its revision increments even
      # though the request is not addressed to it.
      destination = fetch_group(conn, "group-82")
      assert destination["deposit_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 60_000
      assert destination["revision"] == 3

      statement = payment_statement!(conn, "op-pay-1")

      assert statement["reduced_cents"] == 6_000
      assert statement["held_cents"] == 3_000
      assert statement["held_by_group"] == [%{"group_id" => "group-81", "amount_cents" => 3_000}]

      assert ledger(conn)["cash_held_cents"] == 3_000
      assert ledger(conn)["cash_reduced_cents"] == 6_000
    end

    test "a reduction whose other group keeps its funding does not bump it", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9_000})
      )

      open_destination!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"group_id" => "group-82", "amount_cents" => 1_000})
      )

      # Only group-81's own allocation of op-pay-1 is reduced; group-82 is
      # untouched because it holds none of that payment.
      apply_operation!(conn, reduce_operation(%{"amount_cents" => 2_000}))

      assert fetch_group(conn, "group-81")["revision"] == 3
      assert fetch_group(conn, "group-82")["revision"] == 2
      assert fetch_group(conn, "group-82")["deposit_paid_cents"] == 1_000
    end

    test "a chargeback follows a payment's allocations across groups", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9_000})
      )

      open_destination!(conn)

      apply_operation!(conn, transfer_operation(%{"amount_cents" => 4_000}))

      result = apply_operation!(conn, charge_back_operation(%{}))

      assert result["charged_back_cents"] == 9_000
      assert result["group_id"] == "group-81"
      assert result["revision"] == 4

      source = fetch_group(conn, "group-81")
      assert source["deposit_paid_cents"] == 0
      assert source["outstanding_deposit_cents"] == 19_500
      assert source["revision"] == 4

      destination = fetch_group(conn, "group-82")
      assert destination["deposit_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 60_000
      assert destination["revision"] == 3

      statement = payment_statement!(conn, "op-pay-1")

      assert statement["held_cents"] == 0
      assert statement["charged_back_cents"] == 9_000
      assert statement["held_by_group"] == []

      assert ledger(conn)["cash_held_cents"] == 0
      assert ledger(conn)["cash_charged_back_cents"] == 9_000
    end
  end

  describe "later settlement and corrections" do
    test "transferred cash settles under the destination group's policy", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9_000})
      )

      open_destination!(conn, %{"rate_plan" => "advance_purchase"})

      apply_operation!(conn, transfer_operation(%{"amount_cents" => 4_000}))

      # Advance purchase is always non-refundable: the transferred cash is
      # retained, wherever it came from.
      result =
        apply_operation!(conn, cancel_group_operation(%{"group_id" => "group-82"}))

      assert result["retained_cents"] == 4_000

      statement = payment_statement!(conn, "op-pay-1")

      assert statement["retained_cents"] == 4_000
      assert statement["held_cents"] == 5_000
      assert statement["held_by_group"] == [%{"group_id" => "group-81", "amount_cents" => 5_000}]

      assert ledger(conn)["cash_retained_cents"] == 4_000
    end

    test "transferred cash converted to hotel credit receives the bonus", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9_000})
      )

      open_destination!(conn)

      apply_operation!(conn, transfer_operation(%{"amount_cents" => 4_000}))

      result =
        apply_operation!(
          conn,
          cancel_group_operation(%{"group_id" => "group-82", "refund_method" => "hotel_credit"})
        )

      assert result["credit_issued_cents"] == 4_400

      credit = guest_credit(conn, "guest-22")
      assert credit["available_cents"] == 4_400

      statement = payment_statement!(conn, "op-pay-1")

      assert statement["converted_to_credit_cents"] == 4_000
      assert statement["held_cents"] == 5_000
      assert statement["held_by_group"] == [%{"group_id" => "group-81", "amount_cents" => 5_000}]

      assert ledger(conn)["cash_converted_to_credit_cents"] == 4_000
    end

    test "transferred credit restores to its original lot without another bonus", %{conn: conn} do
      issue_credit!(conn, 5_000)

      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9_000})
      )

      apply_operation!(conn, apply_credit_operation(%{"amount_cents" => 1_000}))

      open_destination!(conn)

      # Draws the credit application first (most recent), then cash.
      apply_operation!(conn, transfer_operation(%{"amount_cents" => 1_200}))

      assert guest_credit(conn, "guest-22")["available_cents"] == 4_500

      result =
        apply_operation!(
          conn,
          cancel_group_operation(%{"group_id" => "group-82"})
        )

      # The transferred credit returns to its original lot and expiry; the
      # cash settled in the destination is refunded.
      assert result["refunded_cents"] == 200

      credit = guest_credit(conn, "guest-22")

      assert credit["available_cents"] == 5_500
      assert [%{"remaining_cents" => 5_500, "expires_on" => "2027-11-27"}] = credit["lots"]

      statement = payment_statement!(conn, "op-pay-1")

      assert statement["refunded_cents"] == 200
      assert statement["held_cents"] == 8_800
      assert statement["held_by_group"] == [%{"group_id" => "group-81", "amount_cents" => 8_800}]

      assert ledger(conn)["credit_liability_cents"] == 5_500
    end

    test "restored transferred credit absorbs a lot's shortfall first", %{conn: conn} do
      issue_credit!(conn, 5_000)

      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9_000})
      )

      apply_operation!(conn, apply_credit_operation(%{"amount_cents" => 5_500}))

      open_destination!(conn)

      apply_operation!(conn, transfer_operation(%{"amount_cents" => 1_000}))

      # Charging back the payment that created the lot claws back its whole
      # 5500 entitlement; the lot is exhausted, so it is all unrecovered
      # clawback, and the shortfall is the credit still applied to active
      # groups.
      apply_operation!(
        conn,
        charge_back_operation(%{"payment_operation_id" => "op-pay-fund"})
      )

      assert ledger(conn)["credit_shortfall_cents"] == 5_500

      # A refundable cancellation of the destination returns the transferred
      # credit to the shortfalled lot and extinguishes clawback first.
      apply_operation!(
        conn,
        cancel_group_operation(%{"group_id" => "group-82", "occurred_on" => "2026-11-20"})
      )

      assert ledger(conn)["credit_shortfall_cents"] == 4_500
      assert guest_credit(conn, "guest-22")["available_cents"] == 0
    end
  end

  describe "payment statement evolution" do
    test "held_by_group appears once funding has participated in a transfer", %{conn: conn} do
      funded_source!(conn)
      open_destination!(conn)

      apply_operation!(conn, transfer_operation(%{"amount_cents" => 1_500}))

      statement = payment_statement!(conn, "op-pay-1")

      assert statement["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 8_500},
               %{"group_id" => "group-82", "amount_cents" => 500}
             ]

      # Its amounts sum to held_cents.
      assert Enum.sum_by(statement["held_by_group"], & &1["amount_cents"]) ==
               statement["held_cents"]

      # Payments that never participated keep the earlier statement shape.
      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-3", "amount_cents" => 500})
      )

      refute Map.has_key?(payment_statement!(conn, "op-pay-3"), "held_by_group")
    end

    test "held_by_group becomes an empty list once no cash remains", %{conn: conn} do
      open_group!(conn)

      apply_operation!(
        conn,
        payment_operation(%{"operation_id" => "op-pay-1", "amount_cents" => 9_000})
      )

      open_destination!(conn)

      apply_operation!(conn, transfer_operation(%{"amount_cents" => 4_000}))

      apply_operation!(conn, charge_back_operation(%{}))

      statement = payment_statement!(conn, "op-pay-1")
      assert statement["held_cents"] == 0
      assert statement["held_by_group"] == []
    end

    test "reading a statement never changes state", %{conn: conn} do
      funded_source!(conn)
      open_destination!(conn)

      apply_operation!(conn, transfer_operation(%{"amount_cents" => 1_500}))

      before_ledger = ledger(conn)
      before_group = fetch_group(conn, "group-81")

      payment_statement!(conn, "op-pay-1")
      payment_statement!(conn, "op-pay-1")

      assert ledger(conn) == before_ledger
      assert fetch_group(conn, "group-81") == before_group
    end
  end

  # Simulates a group funded before room accounting existed: the group,
  # payment record, and payment operation are durable, but nothing has been
  # brought forward yet.
  defp insert_pre_accounting_funded_group! do
    Repo.insert!(%Group{
      group_id: "group-81",
      guest_id: "guest-22",
      property_id: "ams-canal",
      booked_on: ~D[2026-10-01],
      arrival_on: ~D[2026-12-10],
      departure_on: ~D[2026-12-13],
      rate_plan: "flexible",
      policy_version: "flex-14",
      status: "active",
      revision: 2,
      lodging_total_cents: 97_500,
      deposit_due_cents: 19_500,
      deposit_paid_cents: 5_000
    })

    Repo.insert!(%Room{
      room_id: "room-a",
      nightly_rate_cents: 15_000,
      position: 0,
      group_id: Repo.get_by!(Group, group_id: "group-81").id
    })

    Repo.insert!(%Room{
      room_id: "room-b",
      nightly_rate_cents: 17_500,
      position: 1,
      group_id: Repo.get_by!(Group, group_id: "group-81").id
    })

    Repo.insert!(%Operation{
      operation_id: "op-pay-1",
      type: "record_cash_payment",
      payload: "{}",
      result:
        Jason.encode!(%{
          "operation_id" => "op-pay-1",
          "status" => "applied",
          "group_id" => "group-81",
          "amount_cents" => 5_000,
          "outstanding_deposit_cents" => 14_500,
          "revision" => 2
        })
    })
  end

  # A group funded with credit first (as a pre-accounting group-level
  # application) and a durable 5000 cash payment afterward. Its funding has
  # not been brought forward yet.
  defp insert_pre_accounting_mixed_group! do
    group =
      Repo.insert!(%Group{
        group_id: "group-81",
        guest_id: "guest-22",
        property_id: "ams-canal",
        booked_on: ~D[2026-10-01],
        arrival_on: ~D[2026-12-10],
        departure_on: ~D[2026-12-13],
        rate_plan: "flexible",
        policy_version: "flex-14",
        status: "active",
        revision: 3,
        lodging_total_cents: 97_500,
        deposit_due_cents: 19_500,
        deposit_paid_cents: 6_000,
        credit_paid_cents: 1_000
      })

    Repo.insert!(%Room{
      room_id: "room-a",
      nightly_rate_cents: 15_000,
      position: 0,
      group_id: group.id
    })

    Repo.insert!(%Room{
      room_id: "room-b",
      nightly_rate_cents: 17_500,
      position: 1,
      group_id: group.id
    })

    lot = Repo.get_by!(Lot, guest_id: "guest-22")

    Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - 1_000))

    Repo.insert!(%CreditApplication{
      group_id: group.id,
      credit_lot_id: lot.id,
      amount_cents: 1_000
    })

    Repo.insert!(%Operation{
      operation_id: "op-pay-1",
      type: "record_cash_payment",
      payload: "{}",
      result:
        Jason.encode!(%{
          "operation_id" => "op-pay-1",
          "status" => "applied",
          "group_id" => "group-81",
          "amount_cents" => 5_000,
          "outstanding_deposit_cents" => 13_500,
          "revision" => 3
        })
    })
  end
end
