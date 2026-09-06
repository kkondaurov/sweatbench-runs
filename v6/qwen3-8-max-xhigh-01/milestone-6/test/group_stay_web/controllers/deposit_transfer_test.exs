defmodule GroupStayWeb.DepositTransferTest do
  use GroupStayWeb.ConnCase

  alias GroupStay.Groups.{CashPayment, Group}
  alias GroupStay.Repo

  @batch_path "/api/v1/partner-batches"
  @group_path "/api/v1/groups"
  @ledger_path "/api/v1/ledger"
  @payments_path "/api/v1/payments"

  defp open_group_op(overrides) do
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
          %{"room_id" => "room-a", "nightly_rate_cents" => 15000},
          %{"room_id" => "room-b", "nightly_rate_cents" => 17500}
        ]
      },
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
        "amount_cents" => 5000
      },
      overrides
    )
  end

  defp transfer_op(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "occurred_on" => "2026-10-06",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 2000
      },
      overrides
    )
  end

  defp reduce_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-reduce",
        "type" => "reduce_cash_payment",
        "occurred_on" => "2026-10-08",
        "payment_operation_id" => "pay-1",
        "amount_cents" => 1000
      },
      overrides
    )
  end

  defp chargeback_op(overrides) do
    Map.merge(
      %{
        "operation_id" => "op-chargeback",
        "type" => "charge_back_payment",
        "occurred_on" => "2026-10-08",
        "payment_operation_id" => "pay-1"
      },
      overrides
    )
  end

  defp post_batch(conn, operations) do
    conn = post(conn, @batch_path, %{operations: operations})
    {conn, json_response(conn, 200)["results"]}
  end

  defp open_group(conn, overrides \\ %{}) do
    {conn, [result]} = post_batch(conn, [open_group_op(overrides)])
    assert %{"status" => "applied"} = result
    {conn, result}
  end

  defp open_second_group(conn) do
    {conn, _} =
      open_group(conn, %{
        "operation_id" => "open-92",
        "group_id" => "group-92",
        "rooms" => [
          %{"room_id" => "room-c", "nightly_rate_cents" => 10000},
          %{"room_id" => "room-d", "nightly_rate_cents" => 12000}
        ]
      })

    conn
  end

  defp pay(conn, op_id, group_id, amount_cents) do
    {conn, [result]} =
      post_batch(conn, [
        payment_op(%{
          "operation_id" => op_id,
          "group_id" => group_id,
          "amount_cents" => amount_cents
        })
      ])

    assert result["status"] == "applied"
    conn
  end

  defp apply_credit(conn, op_id, group_id, amount_cents) do
    {conn, [result]} =
      post_batch(conn, [
        %{
          "operation_id" => op_id,
          "type" => "apply_hotel_credit",
          "occurred_on" => "2026-10-05",
          "group_id" => group_id,
          "amount_cents" => amount_cents
        }
      ])

    assert result["status"] == "applied"
    conn
  end

  # Gives guest-22 a 6600 hotel-credit lot by refundably cancelling a funded
  # group with hotel credit.
  defp issue_credit(conn) do
    {conn, _} =
      open_group(conn, %{
        "operation_id" => "open-70",
        "group_id" => "group-70",
        "rooms" => [%{"room_id" => "room-s", "nightly_rate_cents" => 10000}]
      })

    conn = pay(conn, "pay-70", "group-70", 6000)

    {conn, [result]} =
      post_batch(conn, [
        %{
          "operation_id" => "cancel-70",
          "type" => "cancel_group",
          "occurred_on" => "2026-10-04",
          "group_id" => "group-70",
          "refund_method" => "hotel_credit"
        }
      ])

    assert result["credit_issued_cents"] == 6600
    conn
  end

  defp get_group(conn, group_id) do
    conn = get(conn, "#{@group_path}/#{group_id}")
    {conn, json_response(conn, 200)["data"]}
  end

  defp get_ledger(conn) do
    conn = get(conn, @ledger_path)
    {conn, json_response(conn, 200)["data"]}
  end

  defp get_payment(conn, payment_operation_id) do
    conn = get(conn, "#{@payments_path}/#{payment_operation_id}")
    {conn, json_response(conn, 200)["data"]}
  end

  defp get_guest_credit(conn, on) do
    conn = get(conn, "/api/v1/guests/guest-22/credit", %{"on" => on})
    {conn, json_response(conn, 200)["data"]}
  end

  defp room(group, room_id) do
    Enum.find(group["rooms"], &(&1["room_id"] == room_id))
  end

  describe "transfer_deposit" do
    test "moves held cash between two active groups of the same guest", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [result]} = post_batch(conn, [transfer_op(%{"amount_cents" => 2000})])

      assert result == %{
               "operation_id" => "op-transfer",
               "status" => "applied",
               "source_group_id" => "group-81",
               "destination_group_id" => "group-92",
               "amount_cents" => 2000,
               "source_outstanding_deposit_cents" => 16500,
               "destination_outstanding_deposit_cents" => 11200,
               "source_revision" => 3,
               "destination_revision" => 2
             }

      {conn, source} = get_group(conn, "group-81")
      assert source["cash_paid_cents"] == 3000
      assert source["outstanding_deposit_cents"] == 16500
      assert source["revision"] == 3
      assert room(source, "room-a")["cash_paid_cents"] == 3000

      {_conn, destination} = get_group(conn, "group-92")
      assert destination["cash_paid_cents"] == 2000
      assert destination["outstanding_deposit_cents"] == 11200
      assert destination["revision"] == 2
      assert room(destination, "room-c")["cash_paid_cents"] == 2000
      assert room(destination, "room-d")["cash_paid_cents"] == 0
    end

    test "changes no ledger total", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, ledger_before} = get_ledger(conn)
      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 2000})])
      {_conn, ledger_after} = get_ledger(conn)

      assert ledger_before == ledger_after
      assert ledger_after["cash_held_cents"] == 5000
    end

    test "draws from the source in reverse allocation order regardless of kind", %{conn: conn} do
      conn = issue_credit(conn)
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = apply_credit(conn, "apply-1", "group-81", 3000)
      conn = open_second_group(conn)

      {conn, [result]} = post_batch(conn, [transfer_op(%{"amount_cents" => 4000})])
      assert result["status"] == "applied"

      {conn, source} = get_group(conn, "group-81")
      # the credit (allocated last) moves before the cash
      assert room(source, "room-a")["cash_paid_cents"] == 4000
      assert room(source, "room-a")["credit_paid_cents"] == 0

      {_conn, destination} = get_group(conn, "group-92")
      assert room(destination, "room-c")["credit_paid_cents"] == 3000
      assert room(destination, "room-c")["cash_paid_cents"] == 1000
    end

    test "fills the destination in its original room order preserving drawn order", %{
      conn: conn
    } do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = pay(conn, "pay-2", "group-81", 6000)
      conn = open_second_group(conn)

      # draws pay-2 completely (most recent first) and then 1000 of pay-1
      {conn, [result]} = post_batch(conn, [transfer_op(%{"amount_cents" => 7000})])
      assert result["status"] == "applied"

      {conn, source} = get_group(conn, "group-81")
      assert room(source, "room-a")["cash_paid_cents"] == 4000
      assert room(source, "room-b")["cash_paid_cents"] == 0

      {conn, destination} = get_group(conn, "group-92")
      assert room(destination, "room-c")["cash_paid_cents"] == 6000
      assert room(destination, "room-d")["cash_paid_cents"] == 1000

      # reducing pay-2 removes its transferred units in reverse allocation
      # order, which were placed before pay-1's unit
      {conn, [_]} =
        post_batch(conn, [
          reduce_op(%{"payment_operation_id" => "pay-2", "amount_cents" => 6000})
        ])

      {_conn, destination} = get_group(conn, "group-92")
      assert room(destination, "room-c")["cash_paid_cents"] == 0
      assert room(destination, "room-d")["cash_paid_cents"] == 1000
    end

    test "can move the complete held funding", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [result]} = post_batch(conn, [transfer_op(%{"amount_cents" => 5000})])
      assert result["status"] == "applied"
      assert result["source_outstanding_deposit_cents"] == 19500
      assert result["destination_outstanding_deposit_cents"] == 8200

      {conn, source} = get_group(conn, "group-81")
      assert source["cash_paid_cents"] == 0

      {_conn, destination} = get_group(conn, "group-92")
      assert destination["cash_paid_cents"] == 5000
    end

    test "is rejected with invalid_amount when the amount is not positive", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {_conn, results} =
        post_batch(conn, [
          transfer_op(%{"operation_id" => "t-1", "amount_cents" => 0}),
          transfer_op(%{"operation_id" => "t-2", "amount_cents" => -5})
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_amount"} = result
      end
    end

    test "is rejected when the amount exceeds the source's held funding", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [result]} = post_batch(conn, [transfer_op(%{"amount_cents" => 5001})])

      assert %{"status" => "rejected", "code" => "transfer_exceeds_held_funding"} = result

      {_conn, source} = get_group(conn, "group-81")
      assert source["cash_paid_cents"] == 5000
      assert source["revision"] == 2
    end

    test "is rejected when the amount exceeds the destination's outstanding deposit", %{
      conn: conn
    } do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 19500)
      conn = open_second_group(conn)
      conn = pay(conn, "pay-2", "group-92", 13200)

      {_conn, [result]} = post_batch(conn, [transfer_op(%{"amount_cents" => 1})])

      assert %{"status" => "rejected", "code" => "transfer_exceeds_outstanding"} = result
    end

    test "is rejected as invalid_transfer for the same group or different guests", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [same]} =
        post_batch(conn, [
          transfer_op(%{
            "operation_id" => "t-1",
            "source_group_id" => "group-81",
            "destination_group_id" => "group-81"
          })
        ])

      assert %{"status" => "rejected", "code" => "invalid_transfer"} = same

      {conn, _} =
        open_group(conn, %{
          "operation_id" => "open-93",
          "group_id" => "group-93",
          "guest_id" => "guest-99",
          "rooms" => [%{"room_id" => "room-x", "nightly_rate_cents" => 10000}]
        })

      {_conn, [different]} =
        post_batch(conn, [
          transfer_op(%{"operation_id" => "t-2", "destination_group_id" => "group-93"})
        ])

      assert %{"status" => "rejected", "code" => "invalid_transfer"} = different
    end

    test "is rejected with group_not_active naming the inactive group", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [_]} = post_batch(conn, [cancel_group_op("cancel-81", "group-81")])

      {conn, [source_inactive]} =
        post_batch(conn, [transfer_op(%{"operation_id" => "t-1"})])

      assert source_inactive == %{
               "operation_id" => "t-1",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-81"
             }

      {conn, _} = open_group(conn, %{"operation_id" => "open-84", "group_id" => "group-84"})
      conn = pay(conn, "pay-84", "group-84", 5000)
      {conn, [_]} = post_batch(conn, [cancel_group_op("cancel-92", "group-92")])

      {_conn, [destination_inactive]} =
        post_batch(conn, [
          transfer_op(%{
            "operation_id" => "t-2",
            "source_group_id" => "group-84",
            "destination_group_id" => "group-92"
          })
        ])

      assert destination_inactive == %{
               "operation_id" => "t-2",
               "status" => "rejected",
               "code" => "group_not_active",
               "group_id" => "group-92"
             }
    end

    test "resolves source existence, then destination existence", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [source_missing]} =
        post_batch(conn, [
          transfer_op(%{"operation_id" => "t-1", "source_group_id" => "nope"})
        ])

      assert source_missing == %{
               "operation_id" => "t-1",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "nope"
             }

      # existence is resolved before any revision check
      {_conn, [destination_missing]} =
        post_batch(conn, [
          transfer_op(%{
            "operation_id" => "t-2",
            "destination_group_id" => "nope",
            "expected_revision" => 99
          })
        ])

      assert destination_missing == %{
               "operation_id" => "t-2",
               "status" => "rejected",
               "code" => "group_not_found",
               "group_id" => "nope"
             }
    end

    test "checks the source revision, then the destination revision, before transfer rules",
         %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [source_stale]} =
        post_batch(conn, [
          transfer_op(%{
            "operation_id" => "t-1",
            "expected_revision" => 1,
            "destination_expected_revision" => 99
          })
        ])

      assert source_stale == %{
               "operation_id" => "t-1",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-81",
               "expected_revision" => 1,
               "actual_revision" => 2
             }

      {conn, [destination_stale]} =
        post_batch(conn, [
          transfer_op(%{"operation_id" => "t-2", "destination_expected_revision" => 5})
        ])

      assert destination_stale == %{
               "operation_id" => "t-2",
               "status" => "rejected",
               "code" => "stale_revision",
               "group_id" => "group-92",
               "expected_revision" => 5,
               "actual_revision" => 1
             }

      # revision guards precede the transfer rules
      {conn, [_]} = post_batch(conn, [cancel_group_op("cancel-81", "group-81")])

      {conn, [stale_before_inactive]} =
        post_batch(conn, [
          transfer_op(%{"operation_id" => "t-3", "destination_expected_revision" => 5})
        ])

      assert %{"code" => "stale_revision", "group_id" => "group-92"} = stale_before_inactive

      {_conn, [stale_before_inactive_destination]} =
        post_batch(conn, [
          transfer_op(%{
            "operation_id" => "t-4",
            "source_group_id" => "group-92",
            "destination_group_id" => "group-81",
            "expected_revision" => 99
          })
        ])

      assert %{"code" => "stale_revision", "group_id" => "group-92"} =
               stale_before_inactive_destination
    end

    test "applies when both revision guards match", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {_conn, [result]} =
        post_batch(conn, [
          transfer_op(%{"expected_revision" => 2, "destination_expected_revision" => 1})
        ])

      assert result["status"] == "applied"
      assert result["source_revision"] == 3
      assert result["destination_revision"] == 2
    end

    test "a rejected transfer leaves both groups unchanged", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 5001})])

      {conn, source} = get_group(conn, "group-81")
      assert source["revision"] == 2
      assert source["cash_paid_cents"] == 5000

      {_conn, destination} = get_group(conn, "group-92")
      assert destination["revision"] == 1
      assert destination["cash_paid_cents"] == 0
    end

    test "is durably idempotent", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [first]} = post_batch(conn, [transfer_op()])
      {conn, [retry]} = post_batch(conn, [transfer_op()])

      assert retry == first

      {conn, source} = get_group(conn, "group-81")
      assert source["cash_paid_cents"] == 3000
      assert source["revision"] == 3

      {_conn, destination} = get_group(conn, "group-92")
      assert destination["cash_paid_cents"] == 2000
      assert destination["revision"] == 2
    end

    test "reusing the identifier with a different payload conflicts", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [first]} = post_batch(conn, [transfer_op(%{"amount_cents" => 2000})])
      assert first["status"] == "applied"

      {conn, [conflict]} = post_batch(conn, [transfer_op(%{"amount_cents" => 1000})])

      assert conflict == %{
               "operation_id" => "op-transfer",
               "status" => "rejected",
               "code" => "operation_id_conflict"
             }

      {_conn, source} = get_group(conn, "group-81")
      assert source["cash_paid_cents"] == 3000
    end

    test "the stored result is readable through the operations endpoint", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [first]} = post_batch(conn, [transfer_op()])

      conn = get(conn, "/api/v1/operations/op-transfer")
      assert json_response(conn, 200)["data"] == first
    end

    test "later operations in the same batch observe the transfer", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [first, second]} =
        post_batch(conn, [
          transfer_op(%{"operation_id" => "t-1", "amount_cents" => 2000}),
          transfer_op(%{
            "operation_id" => "t-2",
            "source_group_id" => "group-92",
            "destination_group_id" => "group-81",
            "amount_cents" => 1000
          })
        ])

      assert first["status"] == "applied"
      assert second["status"] == "applied"
      assert second["source_revision"] == 3
      assert second["destination_revision"] == 4

      {conn, source} = get_group(conn, "group-81")
      assert source["cash_paid_cents"] == 4000

      {_conn, destination} = get_group(conn, "group-92")
      assert destination["cash_paid_cents"] == 1000
    end

    test "missing identifying data is an invalid operation", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = open_second_group(conn)

      {_conn, results} =
        post_batch(conn, [
          transfer_op(%{"operation_id" => "t-1"}) |> Map.delete("amount_cents"),
          transfer_op(%{"operation_id" => "t-2"}) |> Map.delete("source_group_id"),
          transfer_op(%{"operation_id" => "t-3"}) |> Map.delete("occurred_on")
        ])

      for result <- results do
        assert %{"status" => "rejected", "code" => "invalid_operation"} = result
      end
    end

    test "a drawn unit that spans destination rooms keeps its provenance", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)
      conn = pay(conn, "pay-2", "group-92", 4500)

      {conn, [result]} = post_batch(conn, [transfer_op(%{"amount_cents" => 5000})])
      assert result["status"] == "applied"

      {conn, destination} = get_group(conn, "group-92")
      assert room(destination, "room-c")["cash_paid_cents"] == 6000
      assert room(destination, "room-d")["cash_paid_cents"] == 3500

      {conn, source} = get_group(conn, "group-81")
      assert source["cash_paid_cents"] == 0

      {conn, statement} = get_payment(conn, "pay-1")
      assert statement["held_cents"] == 5000
      assert statement["held_by_group"] == [%{"group_id" => "group-92", "amount_cents" => 5000}]

      # reducing removes the most recently placed units first
      {conn, [_]} =
        post_batch(conn, [
          reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 2000})
        ])

      {_conn, destination} = get_group(conn, "group-92")
      assert room(destination, "room-c")["cash_paid_cents"] == 6000
      assert room(destination, "room-d")["cash_paid_cents"] == 1500
    end

    test "fills only the destination's active rooms", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [_]} =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-rooms",
            "type" => "cancel_rooms",
            "occurred_on" => "2026-10-05",
            "group_id" => "group-92",
            "room_ids" => ["room-c"]
          }
        ])

      {conn, [result]} = post_batch(conn, [transfer_op(%{"amount_cents" => 2000})])
      assert result["status"] == "applied"
      assert result["destination_outstanding_deposit_cents"] == 5200

      {_conn, destination} = get_group(conn, "group-92")
      assert room(destination, "room-c")["cash_paid_cents"] == 0
      assert room(destination, "room-d")["cash_paid_cents"] == 2000
    end

    test "moves legacy funding that has no durable payment identity", %{conn: conn} do
      {conn, _} = open_group(conn)

      group = Repo.get_by!(Group, group_id: "group-81")

      %CashPayment{}
      |> CashPayment.create_changeset(%{
        group_id: group.id,
        amount_cents: 5000,
        occurred_on: ~D[2026-10-04],
        operation_id: nil
      })
      |> Repo.insert!()

      group
      |> Ecto.Changeset.change(
        cash_paid_cents: 5000,
        deposit_paid_cents: 5000,
        outstanding_deposit_cents: 14500
      )
      |> Repo.update!()

      conn = open_second_group(conn)

      {conn, [result]} = post_batch(conn, [transfer_op(%{"amount_cents" => 2000})])
      assert result["status"] == "applied"
      assert result["source_outstanding_deposit_cents"] == 16500

      {conn, source} = get_group(conn, "group-81")
      assert source["cash_paid_cents"] == 3000

      {conn, destination} = get_group(conn, "group-92")
      assert destination["cash_paid_cents"] == 2000

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_held_cents"] == 5000
    end
  end

  describe "later settlement of transferred funding" do
    test "transferred cash settles under the destination's policy as refunded", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 2000})])
      {conn, [_]} = post_batch(conn, [cancel_group_op("cancel-92", "group-92")])

      {conn, ledger} = get_ledger(conn)
      assert ledger["cash_refunded_cents"] == 2000
      assert ledger["cash_held_cents"] == 3000

      {_conn, statement} = get_payment(conn, "pay-1")
      assert statement["refunded_cents"] == 2000
      assert statement["held_cents"] == 3000
      # the settled group no longer holds any of the payment's cash
      assert statement["held_by_group"] == [%{"group_id" => "group-81", "amount_cents" => 3000}]
    end

    test "transferred cash settles under the destination's policy as retained", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 2000})])

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-92", "group-92", %{"occurred_on" => "2026-11-27"})
        ])

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_retained_cents"] == 2000
      assert ledger["cash_held_cents"] == 3000
    end

    test "converted transferred cash receives the bonus at the destination", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)
      conn = pay(conn, "pay-2", "group-92", 1000)

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 2000})])

      {conn, [cancel]} =
        post_batch(conn, [
          cancel_group_op("cancel-92", "group-92", %{"refund_method" => "hotel_credit"})
        ])

      # combined destination cash 3000 -> bonus 300
      assert cancel["credit_issued_cents"] == 3300

      {conn, ledger} = get_ledger(conn)
      assert ledger["cash_converted_to_credit_cents"] == 3000

      {conn, statement} = get_payment(conn, "pay-1")
      assert statement["converted_to_credit_cents"] == 2000
      # only the group that still holds the payment's cash is listed
      assert statement["held_by_group"] == [%{"group_id" => "group-81", "amount_cents" => 3000}]

      {_conn, statement} = get_payment(conn, "pay-2")
      assert statement["converted_to_credit_cents"] == 1000
      # pay-2 never participated in a transfer
      refute Map.has_key?(statement, "held_by_group")
    end

    test "transferred credit remains applied with expiry paused", %{conn: conn} do
      conn = issue_credit(conn)
      {conn, _} = open_group(conn)
      conn = apply_credit(conn, "apply-1", "group-81", 3000)
      conn = open_second_group(conn)

      {conn, credit_before} = get_guest_credit(conn, "2026-10-06")

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 3000})])

      {conn, credit_after} = get_guest_credit(conn, "2026-10-06")
      assert credit_before == credit_after
      assert credit_after["available_cents"] == 3600
      {conn, ledger} = get_ledger(conn)
      assert ledger["credit_liability_cents"] == 6600

      {_conn, destination} = get_group(conn, "group-92")
      assert room(destination, "room-c")["credit_paid_cents"] == 3000
    end

    test "refundable destination settlement restores transferred credit without another bonus",
         %{conn: conn} do
      conn = issue_credit(conn)
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = apply_credit(conn, "apply-1", "group-81", 3000)
      conn = open_second_group(conn)

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 4000})])
      {conn, [_]} = post_batch(conn, [cancel_group_op("cancel-92", "group-92")])

      {conn, credit} = get_guest_credit(conn, "2026-10-07")
      # restored to the original lot at its original value, no second bonus
      assert credit["available_cents"] == 6600

      {conn, ledger} = get_ledger(conn)
      assert ledger["cash_refunded_cents"] == 1000
      assert ledger["credit_liability_cents"] == 6600

      {_conn, source} = get_group(conn, "group-81")
      assert room(source, "room-a")["cash_paid_cents"] == 4000
      assert room(source, "room-a")["credit_paid_cents"] == 0
    end

    test "non-refundable destination settlement consumes transferred credit", %{conn: conn} do
      conn = issue_credit(conn)
      {conn, _} = open_group(conn)
      conn = apply_credit(conn, "apply-1", "group-81", 3000)
      conn = open_second_group(conn)

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 3000})])

      {conn, [_]} =
        post_batch(conn, [
          cancel_group_op("cancel-92", "group-92", %{"occurred_on" => "2026-11-27"})
        ])

      {conn, credit} = get_guest_credit(conn, "2026-11-27")
      assert credit["available_cents"] == 3600

      {_conn, ledger} = get_ledger(conn)
      assert ledger["credit_liability_cents"] == 3600
    end

    test "restoration of transferred credit is absorbed by an existing shortfall", %{conn: conn} do
      {conn, _} =
        open_group(conn, %{
          "operation_id" => "open-70",
          "group_id" => "group-70",
          "rooms" => [%{"room_id" => "room-s", "nightly_rate_cents" => 15000}]
        })

      conn = pay(conn, "pay-70", "group-70", 8000)

      {conn, [_]} =
        post_batch(conn, [
          %{
            "operation_id" => "cancel-70",
            "type" => "cancel_group",
            "occurred_on" => "2026-10-04",
            "group_id" => "group-70",
            "refund_method" => "hotel_credit"
          }
        ])

      {conn, _} = open_group(conn)
      conn = apply_credit(conn, "apply-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 5000})])

      {conn, [_]} =
        post_batch(conn, [
          chargeback_op(%{"payment_operation_id" => "pay-70"})
        ])

      {conn, ledger} = get_ledger(conn)
      assert ledger["credit_shortfall_cents"] == 5000
      assert ledger["credit_liability_cents"] == 5000

      # the clawback changed no funding in the destination
      {conn, destination} = get_group(conn, "group-92")
      assert destination["revision"] == 2
      assert room(destination, "room-c")["credit_paid_cents"] == 5000

      {conn, [_]} = post_batch(conn, [cancel_group_op("cancel-92", "group-92")])

      {conn, ledger} = get_ledger(conn)
      assert ledger["credit_shortfall_cents"] == 0
      assert ledger["credit_liability_cents"] == 0

      {_conn, credit} = get_guest_credit(conn, "2026-10-07")
      assert credit["available_cents"] == 0
    end
  end

  describe "revisions across groups" do
    test "a reduction follows held cash across groups in reverse allocation order", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 3000})])

      {conn, [result]} =
        post_batch(conn, [reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 4000})])

      # the transferred units (allocated later) are removed first
      assert result == %{
               "operation_id" => "op-reduce",
               "status" => "applied",
               "payment_operation_id" => "pay-1",
               "group_id" => "group-81",
               "amount_cents" => 4000,
               "outstanding_deposit_cents" => 18500,
               "revision" => 4
             }

      {conn, destination} = get_group(conn, "group-92")
      assert destination["revision"] == 3
      assert destination["cash_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 13200

      {conn, source} = get_group(conn, "group-81")
      assert source["cash_paid_cents"] == 1000
      assert source["outstanding_deposit_cents"] == 18500

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_held_cents"] == 1000
      assert ledger["cash_reduced_cents"] == 4000
    end

    test "a reduction increments the addressed group even when nothing is removed there", %{
      conn: conn
    } do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 5000})])

      {conn, [result]} =
        post_batch(conn, [reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 1000})])

      assert result["status"] == "applied"
      assert result["revision"] == 4
      assert result["outstanding_deposit_cents"] == 19500

      {conn, source} = get_group(conn, "group-81")
      assert source["revision"] == 4
      assert source["cash_paid_cents"] == 0

      {_conn, destination} = get_group(conn, "group-92")
      assert destination["revision"] == 3
      assert destination["cash_paid_cents"] == 4000
    end

    test "a chargeback follows held cash across groups", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 3000})])

      {conn, [result]} =
        post_batch(conn, [chargeback_op(%{"payment_operation_id" => "pay-1"})])

      assert result == %{
               "operation_id" => "op-chargeback",
               "status" => "applied",
               "payment_operation_id" => "pay-1",
               "group_id" => "group-81",
               "charged_back_cents" => 5000,
               "outstanding_deposit_cents" => 19500,
               "revision" => 4
             }

      {conn, destination} = get_group(conn, "group-92")
      assert destination["revision"] == 3
      assert destination["cash_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 13200

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_held_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
    end

    test "a chargeback reclassifies settled cash where it was settled", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 3000})])
      {conn, [_]} = post_batch(conn, [cancel_group_op("cancel-92", "group-92")])

      {conn, ledger} = get_ledger(conn)
      assert ledger["cash_refunded_cents"] == 3000

      {conn, [result]} =
        post_batch(conn, [chargeback_op(%{"payment_operation_id" => "pay-1"})])

      assert result["charged_back_cents"] == 5000
      assert result["revision"] == 4

      {conn, destination} = get_group(conn, "group-92")
      assert destination["revision"] == 4

      {_conn, ledger} = get_ledger(conn)
      assert ledger["cash_refunded_cents"] == 0
      assert ledger["cash_charged_back_cents"] == 5000
    end
  end

  describe "payment statement evolution" do
    test "adds held_by_group ordered by group_id once funding participated in a transfer", %{
      conn: conn
    } do
      {conn, _} = open_group(conn)
      conn = open_second_group(conn)
      conn = pay(conn, "pay-1", "group-92", 5000)

      {conn, [_]} =
        post_batch(conn, [
          transfer_op(%{
            "source_group_id" => "group-92",
            "destination_group_id" => "group-81",
            "amount_cents" => 2000
          })
        ])

      {_conn, statement} = get_payment(conn, "pay-1")

      assert statement["held_cents"] == 5000

      assert statement["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 2000},
               %{"group_id" => "group-92", "amount_cents" => 3000}
             ]
    end

    test "a payment that never participated keeps the earlier statement shape", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)

      {_conn, statement} = get_payment(conn, "pay-1")
      refute Map.has_key?(statement, "held_by_group")
    end

    test "returns an empty list once no held cash remains", %{conn: conn} do
      {conn, _} = open_group(conn)
      conn = pay(conn, "pay-1", "group-81", 5000)
      conn = open_second_group(conn)

      {conn, [_]} = post_batch(conn, [transfer_op(%{"amount_cents" => 2000})])

      {conn, statement} = get_payment(conn, "pay-1")

      assert statement["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 3000},
               %{"group_id" => "group-92", "amount_cents" => 2000}
             ]

      {conn, [_]} =
        post_batch(conn, [
          reduce_op(%{"payment_operation_id" => "pay-1", "amount_cents" => 5000})
        ])

      {_conn, statement} = get_payment(conn, "pay-1")
      assert statement["held_cents"] == 0
      assert statement["held_by_group"] == []
    end
  end

  defp cancel_group_op(operation_id, group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => operation_id,
        "type" => "cancel_group",
        "occurred_on" => "2026-10-07",
        "group_id" => group_id
      },
      overrides
    )
  end
end
