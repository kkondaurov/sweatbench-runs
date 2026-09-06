defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  defp submit(conn, operations) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post("/api/v1/partner-batches", Jason.encode!(%{operations: operations}))
  end

  defp results(conn), do: json_response(conn, 200)["results"]

  defp single_result(conn, operations) do
    [result] = conn |> submit(operations) |> results()
    result
  end

  # Two rooms for three nights: room-a lodging 45000 deposit 9000, room-b
  # lodging 52500 deposit 10500. Flex-14 refundable through 2026-11-26.
  defp open_group_op(op_id, group_id, overrides) do
    Map.merge(
      %{
        "operation_id" => op_id,
        "type" => "open_group",
        "occurred_on" => "2026-10-03",
        "group_id" => group_id,
        "guest_id" => "guest-22",
        "property_id" => "ams-canal",
        "arrival_on" => "2026-12-10",
        "departure_on" => "2026-12-13",
        "rate_plan" => "flexible",
        "rooms" => [
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
      overrides
    )
  end

  defp open_group(conn, op_id, group_id, overrides \\ %{}) do
    result = single_result(conn, [open_group_op(op_id, group_id, overrides)])
    assert result["status"] == "applied"
    result
  end

  defp pay(conn, op_id, group_id, amount_cents, overrides \\ %{}) do
    op =
      Map.merge(
        %{
          "operation_id" => op_id,
          "type" => "record_cash_payment",
          "occurred_on" => "2026-10-04",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        },
        overrides
      )

    result = single_result(conn, [op])
    assert result["status"] == "applied"
    result
  end

  defp apply_credit(conn, op_id, group_id, amount_cents) do
    result =
      single_result(conn, [
        %{
          "operation_id" => op_id,
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-10-05",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        }
      ])

    assert result["status"] == "applied"
    result
  end

  defp cancel(conn, op_id, group_id, occurred_on, refund_method \\ "cash") do
    result =
      single_result(conn, [
        %{
          "operation_id" => op_id,
          "type" => "cancel_group",
          "occurred_on" => occurred_on,
          "group_id" => group_id,
          "refund_method" => refund_method
        }
      ])

    assert result["status"] == "applied"
    result
  end

  defp transfer_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 5000
      },
      overrides
    )
  end

  defp transfer(conn, overrides \\ %{}) do
    result = single_result(conn, [transfer_op(overrides)])
    assert result["status"] == "applied"
    result
  end

  # Issues a 1100-cent lot for guest-22 expiring 2027-10-04.
  defp issue_credit(conn) do
    open_group(conn, "op-open-credit", "group-credit")
    pay(conn, "op-pay-credit", "group-credit", 1000)

    result =
      single_result(conn, [
        %{
          "operation_id" => "op-cancel-credit",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-credit",
          "refund_method" => "hotel_credit"
        }
      ])

    assert result["status"] == "applied"
    assert result["credit_issued_cents"] == 1100
  end

  defp get_group(conn, group_id) do
    conn |> get("/api/v1/groups/#{group_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_ledger(conn) do
    conn |> get("/api/v1/ledger") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_credit(conn, guest_id) do
    conn |> get("/api/v1/guests/#{guest_id}/credit") |> json_response(200) |> Map.fetch!("data")
  end

  defp get_payment(conn, payment_operation_id) do
    conn
    |> get("/api/v1/payments/#{payment_operation_id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp room_by_id(group, room_id) do
    Enum.find(group["rooms"], &(&1["room_id"] == room_id))
  end

  describe "moving held funding" do
    test "moves held cash between two groups of the same guest", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 13000)

      result = transfer(conn)

      assert result == %{
               "operation_id" => "op-transfer",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-92",
               "amount_cents" => 5000,
               "source_outstanding_deposit_cents" => 11500,
               "destination_outstanding_deposit_cents" => 14500,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      source = get_group(conn, "group-81")
      assert source["deposit_paid_cents"] == 8000
      assert source["outstanding_deposit_cents"] == 11500

      # The most recently created allocation moves first: room-b's 4000,
      # then 1000 from room-a.
      assert room_by_id(source, "room-a")["cash_paid_cents"] == 8000
      assert room_by_id(source, "room-b")["cash_paid_cents"] == 0

      # The destination fills its active rooms in their original order.
      destination = get_group(conn, "group-92")
      assert destination["deposit_paid_cents"] == 5000
      assert destination["outstanding_deposit_cents"] == 14500
      assert room_by_id(destination, "room-a")["cash_paid_cents"] == 5000
      assert room_by_id(destination, "room-b")["cash_paid_cents"] == 0

      # No ledger total changes.
      ledger = get_ledger(conn)
      assert ledger["cash_held_cents"] == 13000
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_retained_cents"] == 0
      assert ledger["cash_converted_to_credit_cents"] == 0
      assert ledger["cash_reduced_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 0
      assert ledger["credit_liability_cents"] == 0
    end

    test "draws mixed funding in reverse allocation order regardless of kind",
         %{conn: conn} do
      issue_credit(conn)
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")

      pay(conn, "op-pay-1", "group-81", 5000)
      pay(conn, "op-pay-2", "group-81", 6000)
      apply_credit(conn, "op-credit", "group-81", 1100)

      # room-a holds 9000 cash, room-b holds 2000 cash and 1100 credit.
      result = transfer(conn, %{"amount_cents" => 4000})
      assert result["source_revision"] == 5
      assert result["destination_revision"] == 2

      source = get_group(conn, "group-81")
      # Credit moves first, then room-b's cash, then 900 from room-a.
      assert room_by_id(source, "room-a")["cash_paid_cents"] == 8100
      assert room_by_id(source, "room-b")["cash_paid_cents"] == 0
      assert room_by_id(source, "room-b")["credit_paid_cents"] == 0
      assert source["credit_paid_cents"] == 0

      destination = get_group(conn, "group-92")
      assert room_by_id(destination, "room-a")["cash_paid_cents"] == 2900
      assert room_by_id(destination, "room-a")["credit_paid_cents"] == 1100
      assert destination["deposit_paid_cents"] == 4000
      assert destination["credit_paid_cents"] == 1100

      # The moved cash keeps its payment identity.
      statement = get_payment(conn, "op-pay-2")
      assert statement["held_cents"] == 6000

      assert statement["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 3100},
               %{"group_id" => "group-92", "amount_cents" => 2900}
             ]

      # The untouched payment keeps the earlier statement shape.
      refute Map.has_key?(get_payment(conn, "op-pay-1"), "held_by_group")

      # The moved credit keeps its original lot; no bonus is computed and
      # no liability changes.
      assert get_credit(conn, "guest-22")["available_cents"] == 0
      assert get_ledger(conn)["credit_liability_cents"] == 1100
    end

    test "preserves the draw order across the destination's rooms", %{conn: conn} do
      issue_credit(conn)
      open_group(conn, "op-open-source", "group-81")
      pay(conn, "op-pay", "group-81", 5000)
      apply_credit(conn, "op-credit", "group-81", 1100)

      # Two one-night rooms with 1000-cent deposits.
      open_group(conn, "op-open-destination", "group-92", %{
        "departure_on" => "2026-12-11",
        "rooms" => [
          %{"room_id" => "room-x", "nightly_rate_cents" => 5000},
          %{"room_id" => "room-y", "nightly_rate_cents" => 5000}
        ]
      })

      # Credit is drawn first and spans the room boundary before the cash.
      assert transfer(conn, %{"amount_cents" => 2000})["amount_cents"] == 2000

      destination = get_group(conn, "group-92")
      assert room_by_id(destination, "room-x")["credit_paid_cents"] == 1000
      assert room_by_id(destination, "room-x")["cash_paid_cents"] == 0
      assert room_by_id(destination, "room-y")["credit_paid_cents"] == 100
      assert room_by_id(destination, "room-y")["cash_paid_cents"] == 900
    end

    test "continues filling the destination's remaining capacity", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay-source", "group-81", 11000)
      pay(conn, "op-pay-destination", "group-92", 5000)

      transfer(conn, %{"amount_cents" => 6000})

      destination = get_group(conn, "group-92")
      assert room_by_id(destination, "room-a")["cash_paid_cents"] == 9000
      assert room_by_id(destination, "room-b")["cash_paid_cents"] == 2000
      assert destination["outstanding_deposit_cents"] == 8500
    end

    test "can move a group's complete held funding", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 13000)

      result = transfer(conn, %{"amount_cents" => 13000})
      assert result["source_outstanding_deposit_cents"] == 19500
      assert result["destination_outstanding_deposit_cents"] == 6500

      source = get_group(conn, "group-81")
      assert source["deposit_paid_cents"] == 0
      assert room_by_id(source, "room-a")["cash_paid_cents"] == 0
      assert room_by_id(source, "room-b")["cash_paid_cents"] == 0

      assert get_ledger(conn)["cash_held_cents"] == 13000
    end

    test "does not change the guest's credit view", %{conn: conn} do
      issue_credit(conn)
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      apply_credit(conn, "op-credit", "group-81", 1100)

      before = get_credit(conn, "guest-22")
      transfer(conn, %{"amount_cents" => 1100})

      assert get_credit(conn, "guest-22") == before
      assert get_ledger(conn)["credit_liability_cents"] == 1100
    end
  end

  describe "rejections" do
    test "rejects transfers that cannot identify two usable groups", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92", %{"guest_id" => "guest-99"})

      # The same group on both sides.
      result =
        single_result(conn, [
          transfer_op(%{"operation_id" => "op-same", "destination_group_id" => "group-81"})
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "invalid_transfer"

      # Different guests.
      result = single_result(conn, [transfer_op(%{"operation_id" => "op-guests"})])
      assert result["status"] == "rejected"
      assert result["code"] == "invalid_transfer"

      # A missing source, then a missing destination.
      result =
        single_result(conn, [
          transfer_op(%{"operation_id" => "op-no-source", "source_group_id" => "nope"})
        ])

      assert result == %{
               "operation_id" => "op-no-source",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "nope"
             }

      result =
        single_result(conn, [
          transfer_op(%{
            "operation_id" => "op-no-destination",
            "source_group_id" => "group-81",
            "destination_group_id" => "nope"
          })
        ])

      assert result == %{
               "operation_id" => "op-no-destination",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "nope"
             }

      assert get_group(conn, "group-81")["revision"] == 1
      assert get_group(conn, "group-92")["revision"] == 1
    end

    test "rejects inactive groups with the inactive group's identifier", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      cancel(conn, "op-cancel-source", "group-81", "2026-11-26")

      result = single_result(conn, [transfer_op(%{"operation_id" => "op-source-down"})])

      assert result == %{
               "operation_id" => "op-source-down",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-81"
             }

      open_group(conn, "op-open-third", "group-93")
      cancel(conn, "op-cancel-destination", "group-92", "2026-11-26")

      result =
        single_result(conn, [
          transfer_op(%{
            "operation_id" => "op-destination-down",
            "source_group_id" => "group-93",
            "destination_group_id" => "group-92"
          })
        ])

      assert result == %{
               "operation_id" => "op-destination-down",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-92"
             }
    end

    test "rejects unusable amounts and amounts beyond the held or outstanding funding",
         %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 5000)

      for {overrides, index} <-
            Enum.with_index([
              %{"amount_cents" => 0},
              %{"amount_cents" => -5},
              %{"amount_cents" => "500"}
            ]) do
        result =
          single_result(conn, [
            transfer_op(Map.merge(overrides, %{"operation_id" => "op-bad-amount-#{index}"}))
          ])

        assert result["status"] == "rejected"
        assert result["code"] == "invalid_amount"
      end

      # More than the source holds.
      result =
        single_result(conn, [
          transfer_op(%{"operation_id" => "op-too-much-held", "amount_cents" => 5001})
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "transfer_exceeds_held_funding"

      # More than the destination's outstanding deposit.
      pay(conn, "op-pay-destination", "group-92", 19000)

      result =
        single_result(conn, [
          transfer_op(%{"operation_id" => "op-too-much-outstanding", "amount_cents" => 1000})
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "transfer_exceeds_outstanding"

      # Held funding is checked before outstanding deposit.
      result =
        single_result(conn, [
          transfer_op(%{"operation_id" => "op-both", "amount_cents" => 20000})
        ])

      assert result["status"] == "rejected"
      assert result["code"] == "transfer_exceeds_held_funding"

      # The complete operation was rejected every time.
      assert get_group(conn, "group-81")["revision"] == 2
      assert get_group(conn, "group-92")["revision"] == 2
      assert get_ledger(conn)["cash_held_cents"] == 24000
    end

    test "rejects a malformed operation", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")

      variants = [
        Map.delete(transfer_op(%{}), "source_group_id"),
        Map.delete(transfer_op(%{}), "destination_group_id"),
        Map.delete(transfer_op(%{}), "amount_cents"),
        %{transfer_op(%{}) | "source_group_id" => 42},
        %{transfer_op(%{}) | "destination_group_id" => ""}
      ]

      for {op, index} <- Enum.with_index(variants) do
        op = Map.put(op, "operation_id", "op-malformed-#{index}")
        [result] = results(submit(conn, [op]))
        assert result["status"] == "rejected"
        assert result["code"] == "invalid_operation"
      end

      assert get_group(conn, "group-81")["revision"] == 1
      assert get_group(conn, "group-92")["revision"] == 1
    end
  end

  describe "validation order" do
    test "resolves existence before revisions and transfer rules", %{conn: conn} do
      result =
        single_result(conn, [
          transfer_op(%{
            "operation_id" => "op-missing",
            "source_group_id" => "nope",
            "expected_revision" => 99
          })
        ])

      assert result["code"] == "group_not_found"
      assert result["group_id"] == "nope"
    end

    test "checks the source revision before the destination revision", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")

      result =
        single_result(conn, [
          transfer_op(%{
            "operation_id" => "op-both-stale",
            "expected_revision" => 98,
            "destination_expected_revision" => 99
          })
        ])

      assert result == %{
               "operation_id" => "op-both-stale",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 98,
               "actual_revision" => 1
             }
    end

    test "reports a stale destination revision with the destination's details",
         %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 5000)

      result =
        single_result(conn, [
          transfer_op(%{
            "operation_id" => "op-stale-destination",
            "destination_expected_revision" => 99
          })
        ])

      assert result == %{
               "operation_id" => "op-stale-destination",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-92",
               "expected_revision" => 99,
               "actual_revision" => 1
             }

      assert get_group(conn, "group-81")["revision"] == 2
      assert get_group(conn, "group-92")["revision"] == 1
    end

    test "checks revisions before the transfer rules", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      pay(conn, "op-pay", "group-81", 5000)

      # A stale source revision is reported even when the groups are the
      # same and the destination is missing.
      result =
        single_result(conn, [
          transfer_op(%{
            "operation_id" => "op-stale-first",
            "destination_group_id" => "group-81",
            "expected_revision" => 99
          })
        ])

      assert result["code"] == "stale_revision"
      assert result["group_id"] == "group-81"
    end

    test "checks the transfer rules before the amount rules", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      cancel(conn, "op-cancel", "group-81", "2026-11-26")

      result =
        single_result(conn, [
          transfer_op(%{
            "operation_id" => "op-inactive-first",
            "destination_group_id" => "group-81",
            "amount_cents" => 0
          })
        ])

      assert result["code"] == "invalid_transfer"

      open_group(conn, "op-open-destination", "group-92")
      cancel(conn, "op-cancel-destination", "group-92", "2026-11-26")

      result =
        single_result(conn, [
          transfer_op(%{"operation_id" => "op-not-active-first", "amount_cents" => 0})
        ])

      assert result["code"] == "group_not_active"
      assert result["group_id"] == "group-81"
    end
  end

  describe "revisions across groups" do
    test "increments both groups' revisions exactly once", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 5000)

      result = transfer(conn, %{"expected_revision" => 2, "destination_expected_revision" => 1})
      assert result["source_revision"] == 3
      assert result["destination_revision"] == 2

      assert get_group(conn, "group-81")["revision"] == 3
      assert get_group(conn, "group-92")["revision"] == 2

      # A rejected transfer advances neither revision.
      result =
        single_result(conn, [
          transfer_op(%{"operation_id" => "op-rejected", "amount_cents" => 99999})
        ])

      assert result["status"] == "rejected"
      assert get_group(conn, "group-81")["revision"] == 3
      assert get_group(conn, "group-92")["revision"] == 2
    end

    test "reductions follow held allocations across groups", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 13000)
      transfer(conn, %{"operation_id" => "op-transfer"})

      # The payment holds 8000 on group-81 and 5000 on group-92; the
      # destination's newer allocation is removed first.
      result =
        single_result(conn, [
          %{
            "operation_id" => "op-reduce",
            "type" => "reduce_cash_payment",
            "payment_operation_id" => "op-pay",
            "amount_cents" => 8000
          }
        ])

      assert result["status"] == "applied"
      assert result["payment_operation_id"] == "op-pay"
      assert result["group_id"] == "group-81"
      assert result["outstanding_deposit_cents"] == 14500
      assert result["revision"] == 4

      source = get_group(conn, "group-81")
      assert source["deposit_paid_cents"] == 5000
      assert room_by_id(source, "room-a")["cash_paid_cents"] == 5000

      # The destination lost its funding and its revision advanced even
      # though the request was not guarded against it.
      destination = get_group(conn, "group-92")
      assert destination["revision"] == 3
      assert destination["deposit_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 19500
      assert room_by_id(destination, "room-a")["cash_paid_cents"] == 0

      ledger = get_ledger(conn)
      assert ledger["cash_held_cents"] == 5000
      assert ledger["cash_reduced_cents"] == 8000

      statement = get_payment(conn, "op-pay")
      assert statement["held_cents"] == 5000
      assert statement["held_by_group"] == [%{"group_id" => "group-81", "amount_cents" => 5000}]
    end

    test "chargebacks reclassify held and settled portions across groups", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 13000)
      transfer(conn, %{"operation_id" => "op-transfer"})

      # The destination settles its transferred 5000 refundably.
      assert cancel(conn, "op-cancel-destination", "group-92", "2026-11-26")[
               "refunded_cents"
             ] == 5000

      result =
        single_result(conn, [
          %{
            "operation_id" => "op-chargeback",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert result["status"] == "applied"
      assert result["group_id"] == "group-81"
      assert result["charged_back_cents"] == 13000
      assert result["outstanding_deposit_cents"] == 19500
      assert result["revision"] == 4

      # The source lost its held funding.
      source = get_group(conn, "group-81")
      assert source["deposit_paid_cents"] == 0
      assert source["outstanding_deposit_cents"] == 19500

      ledger = get_ledger(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 13000

      statement = get_payment(conn, "op-pay")
      assert statement["held_cents"] == 0
      assert statement["refunded_cents"] == 0
      assert statement["charged_back_cents"] == 13000
      assert statement["held_by_group"] == []
    end

    test "a chargeback removes held funding across all groups it currently funds",
         %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 13000)
      transfer(conn, %{"operation_id" => "op-transfer"})

      result =
        single_result(conn, [
          %{
            "operation_id" => "op-chargeback",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 13000
      assert result["group_id"] == "group-81"
      assert result["revision"] == 4

      # Both groups lost held funding, so both revisions advanced.
      source = get_group(conn, "group-81")
      assert source["revision"] == 4
      assert source["deposit_paid_cents"] == 0
      assert source["outstanding_deposit_cents"] == 19500

      destination = get_group(conn, "group-92")
      assert destination["revision"] == 3
      assert destination["deposit_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 19500

      ledger = get_ledger(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 13000

      assert get_payment(conn, "op-pay")["held_by_group"] == []
    end

    test "a chargeback of converted transferred cash revokes the destination's lot",
         %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 1000)
      transfer(conn, %{"operation_id" => "op-transfer", "amount_cents" => 1000})

      assert cancel(conn, "op-cancel-destination", "group-92", "2026-11-26", "hotel_credit")[
               "credit_issued_cents"
             ] == 1100

      assert get_credit(conn, "guest-22")["available_cents"] == 1100

      result =
        single_result(conn, [
          %{
            "operation_id" => "op-chargeback",
            "type" => "charge_back_payment",
            "payment_operation_id" => "op-pay"
          }
        ])

      assert result["status"] == "applied"
      assert result["charged_back_cents"] == 1000

      assert get_credit(conn, "guest-22")["available_cents"] == 0

      ledger = get_ledger(conn)
      assert ledger["cash_converted_to_credit_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 1000
      assert ledger["credit_liability_cents"] == 0
    end
  end

  describe "later settlement and corrections" do
    test "transferred cash settles under the destination's cancellation policy",
         %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      pay(conn, "op-pay", "group-81", 5000)

      # The destination is advance purchase and never refundable.
      open_group(conn, "op-open-destination", "group-92", %{
        "rate_plan" => "advance_purchase"
      })

      transfer(conn)

      result = cancel(conn, "op-cancel-destination", "group-92", "2026-11-01")
      assert result["refunded_cents"] == 0
      assert result["retained_cents"] == 5000

      ledger = get_ledger(conn)
      assert ledger["cash_retained_cents"] == 5000
      assert ledger["cash_held_cents"] == 0

      statement = get_payment(conn, "op-pay")
      assert statement["retained_cents"] == 5000
      assert statement["held_cents"] == 0
    end

    test "transferred cash converted at the destination receives the bonus there",
         %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 5000)
      transfer(conn)

      result =
        cancel(conn, "op-cancel-destination", "group-92", "2026-11-26", "hotel_credit")

      assert result["credit_issued_cents"] == 5500

      assert get_credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 5500,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-destination",
                   "remaining_cents" => 5500,
                   "expires_on" => "2027-11-26"
                 }
               ]
             }

      assert get_ledger(conn)["cash_converted_to_credit_cents"] == 5000
    end

    test "transferred credit returns to its original lot on a refundable settlement",
         %{conn: conn} do
      issue_credit(conn)
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      apply_credit(conn, "op-credit", "group-81", 1100)
      transfer(conn, %{"amount_cents" => 1100})

      result = cancel(conn, "op-cancel-destination", "group-92", "2026-11-26")
      assert result["refunded_cents"] == 0
      assert result["credit_issued_cents"] == 0

      # The credit is back in its original lot with its original expiry,
      # without another bonus.
      assert get_credit(conn, "guest-22") == %{
               "guest_id" => "guest-22",
               "available_cents" => 1100,
               "lots" => [
                 %{
                   "source_operation_id" => "op-cancel-credit",
                   "remaining_cents" => 1100,
                   "expires_on" => "2027-10-04"
                 }
               ]
             }

      assert get_ledger(conn)["credit_liability_cents"] == 1100
    end

    test "transferred credit is consumed by a non-refundable settlement", %{conn: conn} do
      issue_credit(conn)
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      apply_credit(conn, "op-credit", "group-81", 1100)
      transfer(conn, %{"amount_cents" => 1100})

      cancel(conn, "op-cancel-destination", "group-92", "2026-11-27")

      assert get_credit(conn, "guest-22")["available_cents"] == 0
      assert get_ledger(conn)["credit_liability_cents"] == 0
    end

    test "restored transferred credit is absorbed by an existing shortfall",
         %{conn: conn} do
      # A lot from group-big; charging back its payment while credit from
      # the lot funds another group creates a shortfall.
      open_group(conn, "op-open-big", "group-big", %{
        "departure_on" => "2026-12-11",
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 12000}]
      })

      pay(conn, "op-pay-big", "group-big", 1000)
      cancel(conn, "op-cancel-big", "group-big", "2026-11-20", "hotel_credit")

      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      apply_credit(conn, "op-credit", "group-81", 600)
      transfer(conn, %{"amount_cents" => 600})

      assert single_result(conn, [
               %{
                 "operation_id" => "op-chargeback",
                 "type" => "charge_back_payment",
                 "payment_operation_id" => "op-pay-big"
               }
             ])["status"] == "applied"

      assert get_ledger(conn)["credit_shortfall_cents"] == 600

      # The refundable settlement of the destination restores the credit;
      # the shortfall absorbs it.
      cancel(conn, "op-cancel-destination", "group-92", "2026-11-01")

      assert get_credit(conn, "guest-22")["available_cents"] == 0

      ledger = get_ledger(conn)
      assert ledger["credit_liability_cents"] == 0
      assert ledger["credit_shortfall_cents"] == 0
    end

    test "transferred credit stays applied past its lot's expiry until settlement",
         %{conn: conn} do
      issue_credit(conn)
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      apply_credit(conn, "op-credit", "group-81", 1100)
      transfer(conn, %{"amount_cents" => 1100})

      # Move the destination's arrival far enough that a late cancellation
      # is still refundable, then cancel after the lot's 2027-10-04 expiry.
      assert single_result(conn, [
               %{
                 "operation_id" => "op-move",
                 "type" => "reschedule_group",
                 "occurred_on" => "2026-11-01",
                 "group_id" => "group-92",
                 "new_arrival_on" => "2028-01-10"
               }
             ])["status"] == "applied"

      # The credit is still applied, so it has not expired.
      assert get_credit(conn, "guest-22")["available_cents"] == 0
      assert get_ledger(conn)["credit_liability_cents"] == 1100

      cancel(conn, "op-cancel-destination", "group-92", "2027-10-05")

      # Restored past its original expiry, the credit expires immediately.
      assert get_credit(conn, "guest-22")["available_cents"] == 0
      assert get_ledger(conn)["credit_liability_cents"] == 0
    end
  end

  describe "payment statement evolution" do
    test "adds held_by_group once funding has participated in a transfer", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 13000)

      refute Map.has_key?(get_payment(conn, "op-pay"), "held_by_group")

      transfer(conn)

      statement = get_payment(conn, "op-pay")
      assert statement["held_cents"] == 13000

      assert statement["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 8000},
               %{"group_id" => "group-92", "amount_cents" => 5000}
             ]

      # Moving the remainder back leaves a single entry; the field remains
      # once the payment has participated.
      assert single_result(conn, [
               transfer_op(%{
                 "operation_id" => "op-transfer-back",
                 "source_group_id" => "group-92",
                 "destination_group_id" => "group-81",
                 "amount_cents" => 5000
               })
             ])["status"] == "applied"

      statement = get_payment(conn, "op-pay")
      assert statement["held_cents"] == 13000
      assert statement["held_by_group"] == [%{"group_id" => "group-81", "amount_cents" => 13000}]
    end

    test "reports an empty list once no held cash remains", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 5000)
      transfer(conn)

      assert single_result(conn, [
               %{
                 "operation_id" => "op-reduce",
                 "type" => "reduce_cash_payment",
                 "payment_operation_id" => "op-pay",
                 "amount_cents" => 5000
               }
             ])["status"] == "applied"

      statement = get_payment(conn, "op-pay")
      assert statement["held_cents"] == 0
      assert statement["held_by_group"] == []
    end
  end

  describe "durability" do
    test "is durably idempotent and bumps each revision exactly once", %{conn: conn} do
      open_group(conn, "op-open-source", "group-81")
      open_group(conn, "op-open-destination", "group-92")
      pay(conn, "op-pay", "group-81", 5000)

      first = transfer(conn)
      retry = single_result(conn, [transfer_op()])
      assert retry == first

      assert get_group(conn, "group-81")["revision"] == 3
      assert get_group(conn, "group-92")["revision"] == 2
      assert get_group(conn, "group-81")["deposit_paid_cents"] == 0
      assert get_group(conn, "group-92")["deposit_paid_cents"] == 5000
      assert get_ledger(conn)["cash_held_cents"] == 5000

      # A remembered rejection replays too.
      rejected =
        single_result(conn, [
          transfer_op(%{"operation_id" => "op-bad", "amount_cents" => 0})
        ])

      assert rejected["code"] == "invalid_amount"

      assert single_result(conn, [transfer_op(%{"operation_id" => "op-bad", "amount_cents" => 0})]) ==
               rejected

      # A reused identifier with a different payload conflicts.
      conflict = single_result(conn, [transfer_op(%{"amount_cents" => 1000})])
      assert conflict["status"] == "rejected"
      assert conflict["code"] == "operation_id_conflict"
    end

    test "operations in the same batch observe each other", %{conn: conn} do
      [opened_source, opened_destination, paid, transferred] =
        conn
        |> submit([
          open_group_op("op-open-source", "group-81", %{}),
          open_group_op("op-open-destination", "group-92", %{}),
          %{
            "operation_id" => "op-pay",
            "type" => "record_cash_payment",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-81",
            "amount_cents" => 5000
          },
          transfer_op(%{
            "expected_revision" => 2,
            "destination_expected_revision" => 1
          })
        ])
        |> results()

      assert opened_source["status"] == "applied"
      assert opened_destination["status"] == "applied"
      assert paid["status"] == "applied"

      assert transferred["status"] == "applied"
      assert transferred["source_revision"] == 3
      assert transferred["destination_revision"] == 2
      assert transferred["source_outstanding_deposit_cents"] == 19500
      assert transferred["destination_outstanding_deposit_cents"] == 14500
    end
  end
end
