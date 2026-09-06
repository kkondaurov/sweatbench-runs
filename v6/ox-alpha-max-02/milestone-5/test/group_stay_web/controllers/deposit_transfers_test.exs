defmodule GroupStayWeb.Controllers.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false

  ## Builders

  defp transfer(overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-transfer",
        "type" => "transfer_deposit",
        "source_group_id" => "group-81",
        "destination_group_id" => "group-92",
        "amount_cents" => 3_000
      },
      overrides
    )
  end

  defp pay(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "pay-" <> group_id <> "-" <> Integer.to_string(amount),
        "type" => "record_cash_payment",
        "occurred_on" => "2026-11-01",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp reduce(payment_operation_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" =>
          "op-reduce-" <> payment_operation_id <> "-" <> Integer.to_string(amount),
        "type" => "reduce_cash_payment",
        "payment_operation_id" => payment_operation_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp charge_back(payment_operation_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-charge-back-" <> payment_operation_id,
        "type" => "charge_back_payment",
        "payment_operation_id" => payment_operation_id
      },
      overrides
    )
  end

  defp apply_credit(group_id, amount, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "apply-" <> group_id,
        "type" => "apply_hotel_credit",
        "occurred_on" => "2026-10-25",
        "group_id" => group_id,
        "amount_cents" => amount
      },
      overrides
    )
  end

  defp cancel(group_id, overrides \\ %{}) do
    Map.merge(
      %{
        "operation_id" => "op-cancel-" <> group_id,
        "type" => "cancel_group",
        "occurred_on" => "2026-11-26",
        "group_id" => group_id
      },
      overrides
    )
  end

  defp open_destination(overrides \\ %{}) do
    open_operation(
      Map.merge(
        %{"operation_id" => "op-open-dst", "group_id" => "group-92"},
        overrides
      )
    )
  end

  # Leaves the guest with a credit lot worth 110% of `cash`, issued on
  # `cancelled_on` under operation `op_id`.
  defp issue_lot(conn, op_id, cancelled_on, cash) do
    arrival = cancelled_on |> Date.from_iso8601!() |> Date.add(90) |> Date.to_iso8601()

    run_batch(conn, [
      open_operation(%{
        "operation_id" => "open-src-" <> op_id,
        "group_id" => "g-src-" <> op_id,
        "occurred_on" => cancelled_on,
        "arrival_on" => arrival,
        "departure_on" => arrival |> Date.from_iso8601!() |> Date.add(3) |> Date.to_iso8601(),
        "rooms" => [%{"room_id" => "room-a", "nightly_rate_cents" => 15_000}]
      }),
      pay("g-src-" <> op_id, cash, %{"occurred_on" => cancelled_on}),
      %{
        "operation_id" => op_id,
        "type" => "cancel_group",
        "occurred_on" => cancelled_on,
        "group_id" => "g-src-" <> op_id,
        "refund_method" => "hotel_credit"
      }
    ])
  end

  defp fetch_guest_credit(conn, guest_id) do
    assert %{"data" => data} =
             get(conn, "/api/v1/guests/#{URI.encode_www_form(guest_id)}/credit")
             |> json_response(200)

    data
  end

  defp room_view(group, room_id) do
    Enum.find(group["rooms"], &(&1["room_id"] == room_id))
  end

  defp snapshot(conn) do
    {
      fetch_group(conn, "group-81"),
      fetch_group(conn, "group-92"),
      fetch_ledger(conn)
    }
  end

  ## Moving held funding

  describe "transfer_deposit" do
    test "moves held cash to the destination's rooms and advances both revisions", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 10_000)
      ])

      assert [
               %{
                 "operation_id" => "op-transfer",
                 "status" => "applied",
                 "source_group_id" => "group-81",
                 "destination_group_id" => "group-92",
                 "amount_cents" => 3_000,
                 "source_outstanding_deposit_cents" => 12_500,
                 "destination_outstanding_deposit_cents" => 16_500,
                 "source_revision" => 3,
                 "destination_revision" => 2
               }
             ] = run_batch(conn, [transfer()])

      source = fetch_group(conn, "group-81")
      assert room_view(source, "room-a")["cash_paid_cents"] == 7_000
      assert room_view(source, "room-b")["cash_paid_cents"] == 0
      assert source["cash_paid_cents"] == 7_000
      assert source["outstanding_deposit_cents"] == 12_500
      assert source["revision"] == 3

      destination = fetch_group(conn, "group-92")
      assert room_view(destination, "room-a")["cash_paid_cents"] == 3_000
      assert destination["cash_paid_cents"] == 3_000
      assert destination["outstanding_deposit_cents"] == 16_500
      assert destination["revision"] == 2

      assert_ledger(conn,
        cash_held_cents: 10_000,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        credit_liability_cents: 0
      )

      assert fetch_payment(conn, "pay-group-81-10000")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 7_000},
               %{"group_id" => "group-92", "amount_cents" => 3_000}
             ]
    end

    test "unwinds the most recent allocations first regardless of funding kind", %{conn: conn} do
      issue_lot(conn, "cancel-lot-src", "2026-09-01", 5_000)

      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 10_000),
        apply_credit("group-81", 2_000)
      ])

      # The credit landed on room-b after the cash did, so it is drawn first;
      # then the cash row that filled room-b. Room-a's older cash stays.
      assert [%{"status" => "applied", "source_revision" => 4, "destination_revision" => 2}] =
               run_batch(conn, [transfer(%{"amount_cents" => 3_000})])

      source = fetch_group(conn, "group-81")
      assert room_view(source, "room-a")["cash_paid_cents"] == 9_000
      assert room_view(source, "room-a")["credit_paid_cents"] == 0
      assert room_view(source, "room-b")["cash_paid_cents"] == 0
      assert room_view(source, "room-b")["credit_paid_cents"] == 0
      assert source["outstanding_deposit_cents"] == 10_500

      destination = fetch_group(conn, "group-92")
      assert room_view(destination, "room-a")["credit_paid_cents"] == 2_000
      assert room_view(destination, "room-a")["cash_paid_cents"] == 1_000
      assert room_view(destination, "room-b")["credit_paid_cents"] == 0
      assert room_view(destination, "room-b")["cash_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 16_500

      assert_ledger(conn,
        cash_held_cents: 10_000,
        cash_converted_to_credit_cents: 5_000,
        credit_liability_cents: 5_500
      )

      assert %{"available_cents" => 3_500} = fetch_guest_credit(conn, "guest-22")
    end

    test "transferred cash settles under the destination's policy with its bonus", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 5_000, %{"operation_id" => "pay-move"}),
        transfer(%{"amount_cents" => 2_000})
      ])

      assert [
               %{
                 "status" => "applied",
                 "refunded_cents" => 0,
                 "retained_cents" => 0,
                 "credit_issued_cents" => 2_200,
                 "revision" => 3
               }
             ] =
               run_batch(conn, [
                 cancel("group-92", %{
                   "operation_id" => "cancel-dst",
                   "refund_method" => "hotel_credit"
                 })
               ])

      assert fetch_guest_credit(conn, "guest-22")["lots"] == [
               %{
                 "source_operation_id" => "cancel-dst",
                 "remaining_cents" => 2_200,
                 "expires_on" => "2027-11-27"
               }
             ]

      assert_ledger(conn,
        cash_held_cents: 3_000,
        cash_converted_to_credit_cents: 2_000,
        credit_liability_cents: 2_200
      )

      assert fetch_payment(conn, "pay-move")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 3_000}
             ]

      assert [%{"status" => "applied", "refunded_cents" => 3_000, "revision" => 4}] =
               run_batch(conn, [cancel("group-81", %{"operation_id" => "cancel-src"})])

      assert_ledger(conn,
        cash_held_cents: 0,
        cash_refunded_cents: 3_000,
        cash_converted_to_credit_cents: 2_000,
        credit_liability_cents: 2_200
      )

      assert fetch_payment(conn, "pay-move") == %{
               "payment_operation_id" => "pay-move",
               "original_group_id" => "group-81",
               "recorded_cents" => 5_000,
               "held_cents" => 0,
               "refunded_cents" => 3_000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 2_000,
               "reduced_cents" => 0,
               "charged_back_cents" => 0,
               "held_by_group" => []
             }
    end

    test "transferred credit restores to its original lot without another bonus", %{conn: conn} do
      issue_lot(conn, "cancel-lot-src", "2026-09-01", 5_000)

      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 10_000),
        apply_credit("group-81", 2_000),
        transfer(%{"amount_cents" => 2_000})
      ])

      assert [%{"status" => "applied", "refunded_cents" => 0, "credit_issued_cents" => 0}] =
               run_batch(conn, [
                 cancel("group-92", %{"operation_id" => "cancel-dst", "refund_method" => "cash"})
               ])

      assert fetch_guest_credit(conn, "guest-22")["lots"] == [
               %{
                 "source_operation_id" => "cancel-lot-src",
                 "remaining_cents" => 5_500,
                 "expires_on" => "2027-09-02"
               }
             ]

      # Only the credit moved, so every cent of cash still funds the source.
      assert_ledger(conn,
        cash_held_cents: 10_000,
        cash_converted_to_credit_cents: 5_000,
        credit_liability_cents: 5_500
      )
    end

    test "moves exactly all held funding when asked, and no more", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 100, %{"occurred_on" => "2026-11-02"})
      ])

      assert [%{"status" => "applied"}] =
               run_batch(conn, [transfer(%{"amount_cents" => 100})])

      source = fetch_group(conn, "group-81")
      assert source["outstanding_deposit_cents"] == 19_500
      assert Enum.all?(source["rooms"], &(&1["cash_paid_cents"] == 0))

      assert [%{"status" => "rejected", "code" => "transfer_exceeds_held_funding"}] =
               run_batch(conn, [transfer(%{"amount_cents" => 1, "operation_id" => "op-more"})])
    end

    test "operations later in the same batch observe the transfer", %{conn: conn} do
      results =
        run_batch(conn, [
          open_operation(),
          open_destination(),
          pay("group-81", 10_000),
          transfer(),
          pay("group-92", 16_500, %{
            "operation_id" => "op-fill-dst",
            "expected_revision" => 2
          })
        ])

      assert [
               %{"status" => "applied"},
               %{"status" => "applied"},
               %{"status" => "applied", "revision" => 2},
               %{"status" => "applied", "source_revision" => 3, "destination_revision" => 2},
               %{"status" => "applied", "outstanding_deposit_cents" => 0, "revision" => 3}
             ] = results

      assert fetch_group(conn, "group-92")["deposit_paid_cents"] == 19_500
    end
  end

  ## Rejections

  describe "transfer_deposit rejections" do
    test "uses the documented codes before anything moves", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        open_operation(%{
          "operation_id" => "op-open-other-guest",
          "group_id" => "group-77",
          "guest_id" => "guest-99"
        }),
        pay("group-81", 100, %{"occurred_on" => "2026-11-02"})
      ])

      cases = [
        {%{"source_group_id" => "group-81", "destination_group_id" => "group-81"},
         {"invalid_transfer", nil}},
        {%{"source_group_id" => "group-77", "destination_group_id" => "group-81"},
         {"invalid_transfer", nil}},
        {%{"source_group_id" => "ghost-source"}, {"group_not_found", "ghost-source"}},
        {%{"destination_group_id" => "ghost-destination"},
         {"group_not_found", "ghost-destination"}},
        {%{"amount_cents" => 0}, {"invalid_amount", nil}},
        {%{"amount_cents" => -5}, {"invalid_amount", nil}},
        {%{"amount_cents" => "100"}, {"invalid_amount", nil}},
        {%{"amount_cents" => nil}, {"invalid_amount", nil}},
        {%{"amount_cents" => 101}, {"transfer_exceeds_held_funding", nil}}
      ]

      cases
      |> Enum.with_index()
      |> Enum.each(fn {{overrides, {code, group_id}}, index} ->
        operation = transfer(Map.merge(overrides, %{"operation_id" => "op-tx-bad-#{index}"}))

        assert [result] = run_batch(conn, [operation])
        assert result["status"] == "rejected"
        assert result["code"] == code

        if group_id do
          assert result["group_id"] == group_id
        end
      end)

      # Nothing moved and nothing advanced.
      assert fetch_group(conn, "group-81")["revision"] == 2
      assert fetch_group(conn, "group-92")["revision"] == 1
      assert fetch_payment(conn, "pay-group-81-100")["held_by_group"] == nil

      assert_ledger(conn, cash_held_cents: 100)
    end

    test "checks the source revision first and names each group on its own mismatch", %{
      conn: conn
    } do
      run_batch(conn, [open_operation(), open_destination(), pay("group-81", 100)])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-81",
                 "expected_revision" => 99,
                 "actual_revision" => 2
               }
             ] =
               run_batch(conn, [
                 transfer(%{
                   "expected_revision" => 99,
                   "destination_expected_revision" => 88
                 })
               ])

      assert [
               %{
                 "status" => "rejected",
                 "code" => "stale_revision",
                 "group_id" => "group-92",
                 "expected_revision" => 9,
                 "actual_revision" => 1
               }
             ] =
               run_batch(conn, [
                 transfer(%{
                   "expected_revision" => 2,
                   "destination_expected_revision" => 9,
                   "operation_id" => "op-tx-stale-dst"
                 })
               ])

      # Existence resolves before revisions.
      assert [%{"status" => "rejected", "code" => "group_not_found", "group_id" => "ghost"}] =
               run_batch(conn, [
                 transfer(%{
                   "destination_group_id" => "ghost",
                   "destination_expected_revision" => 9,
                   "operation_id" => "op-tx-missing"
                 })
               ])

      assert fetch_group(conn, "group-81")["revision"] == 2
      assert fetch_group(conn, "group-92")["revision"] == 1
    end

    test "reports which group is not active", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 100),
        cancel("group-81", %{"occurred_on" => "2026-11-20"})
      ])

      assert [%{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-81"}] =
               run_batch(conn, [
                 transfer(%{"operation_id" => "op-tx-inactive-src"})
               ])

      assert [%{"status" => "rejected", "code" => "group_not_active", "group_id" => "group-81"}] =
               run_batch(conn, [
                 transfer(%{
                   "source_group_id" => "group-92",
                   "destination_group_id" => "group-81",
                   "operation_id" => "op-tx-inactive-dst"
                 })
               ])

      assert fetch_group(conn, "group-92")["revision"] == 1
    end

    test "a guest mismatch wins over an inactive group", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_operation(%{
          "operation_id" => "op-open-other-guest",
          "group_id" => "group-77",
          "guest_id" => "guest-99"
        }),
        cancel("group-77", %{"occurred_on" => "2026-11-20"})
      ])

      assert [%{"status" => "rejected", "code" => "invalid_transfer"}] =
               run_batch(conn, [
                 transfer(%{
                   "source_group_id" => "group-77",
                   "destination_group_id" => "group-81",
                   "operation_id" => "op-tx-mixed"
                 })
               ])
    end

    test "the destination's outstanding caps the transfer", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 100, %{"occurred_on" => "2026-11-02"}),
        pay("group-92", 19_500, %{"operation_id" => "op-fill-dst"})
      ])

      assert [%{"status" => "rejected", "code" => "transfer_exceeds_outstanding"}] =
               run_batch(conn, [transfer(%{"amount_cents" => 100})])
    end
  end

  ## Revisions across groups

  describe "reductions and chargebacks across transferred funding" do
    test "a reduction follows the payment across groups and bumps both revisions", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 10_000, %{"operation_id" => "pay-span"}),
        transfer()
      ])

      assert [
               %{
                 "status" => "applied",
                 "payment_operation_id" => "pay-span",
                 "group_id" => "group-81",
                 "amount_cents" => 3_000,
                 "outstanding_deposit_cents" => 12_500,
                 "revision" => 4
               }
             ] =
               run_batch(conn, [
                 reduce("pay-span", 3_000, %{"operation_id" => "op-red-span"})
               ])

      # The transferred allocation was the newest, so it goes first.
      destination = fetch_group(conn, "group-92")
      assert room_view(destination, "room-a")["cash_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 19_500
      assert destination["revision"] == 3

      source = fetch_group(conn, "group-81")
      assert room_view(source, "room-a")["cash_paid_cents"] == 7_000
      assert source["revision"] == 4

      assert_ledger(conn,
        cash_held_cents: 7_000,
        cash_reduced_cents: 3_000
      )

      assert fetch_payment(conn, "pay-span")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 7_000}
             ]

      assert [
               %{
                 "status" => "applied",
                 "charged_back_cents" => 7_000,
                 "outstanding_deposit_cents" => 19_500,
                 "revision" => 5
               }
             ] =
               run_batch(conn, [
                 charge_back("pay-span", %{"operation_id" => "op-cb-span"})
               ])

      assert_ledger(conn,
        cash_held_cents: 0,
        cash_reduced_cents: 3_000,
        cash_charged_back_cents: 7_000
      )

      # The other group's revision only moved while its funding changed.
      assert fetch_group(conn, "group-92")["revision"] == 3

      assert fetch_payment(conn, "pay-span") == %{
               "payment_operation_id" => "pay-span",
               "original_group_id" => "group-81",
               "recorded_cents" => 10_000,
               "held_cents" => 0,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 3_000,
               "charged_back_cents" => 7_000,
               "held_by_group" => []
             }
    end

    test "reversing allocations split across groups unwinds them in reverse order", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 10_000, %{"operation_id" => "pay-split"}),
        transfer(%{"amount_cents" => 4_000})
      ])

      # Held rows after the transfer: source room-a 6_000 (older), destination
      # room-a 4_000 (newer). Removing 5_000 takes the destination row whole
      # plus 1_000 from the source.
      assert [%{"status" => "applied", "revision" => 4}] =
               run_batch(conn, [
                 reduce("pay-split", 5_000, %{"operation_id" => "op-red-split"})
               ])

      source = fetch_group(conn, "group-81")
      assert room_view(source, "room-a")["cash_paid_cents"] == 5_000

      destination = fetch_group(conn, "group-92")
      assert room_view(destination, "room-a")["cash_paid_cents"] == 0
      assert destination["revision"] == 3

      assert_ledger(conn,
        cash_held_cents: 5_000,
        cash_reduced_cents: 5_000
      )

      assert fetch_payment(conn, "pay-split")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 5_000}
             ]
    end

    test "a reduction follows money that outlived its cancelled original group", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 5_000, %{"operation_id" => "pay-survivor"}),
        transfer(%{"amount_cents" => 3_000}),
        cancel("group-81")
      ])

      # Only the 2_000 that stayed home was refunded; the transferred 3_000
      # still funds the active destination and remains reducible.
      assert_ledger(conn,
        cash_held_cents: 3_000,
        cash_refunded_cents: 2_000
      )

      assert [
               %{
                 "status" => "applied",
                 "group_id" => "group-81",
                 "amount_cents" => 3_000,
                 # The result describes the payment's own group, which is
                 # cancelled and therefore has nothing outstanding.
                 "outstanding_deposit_cents" => 0,
                 "revision" => 5
               }
             ] =
               run_batch(conn, [
                 reduce("pay-survivor", 3_000, %{"operation_id" => "op-red-survivor"})
               ])

      # Even the cancelled original group advances once as the addressed group.
      assert fetch_group(conn, "group-81")["revision"] == 5

      destination = fetch_group(conn, "group-92")
      assert room_view(destination, "room-a")["cash_paid_cents"] == 0
      assert destination["outstanding_deposit_cents"] == 19_500
      assert destination["revision"] == 3

      assert_ledger(conn,
        cash_held_cents: 0,
        cash_refunded_cents: 2_000,
        cash_reduced_cents: 3_000
      )

      assert fetch_payment(conn, "pay-survivor") == %{
               "payment_operation_id" => "pay-survivor",
               "original_group_id" => "group-81",
               "recorded_cents" => 5_000,
               "held_cents" => 0,
               "refunded_cents" => 2_000,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 3_000,
               "charged_back_cents" => 0,
               "held_by_group" => []
             }
    end
  end

  ## Payment statement evolution

  describe "payment statement evolution" do
    test "only payments that participated in a transfer gain held_by_group", %{conn: conn} do
      # Destination sorts before the source so ordering cannot be inherited
      # from creation order.
      run_batch(conn, [
        open_operation(%{"group_id" => "group-92"}),
        open_destination(%{"operation_id" => "op-open-a", "group_id" => "group-81"}),
        pay("group-92", 4_000, %{"operation_id" => "pay-q"})
      ])

      assert fetch_payment(conn, "pay-q") == %{
               "payment_operation_id" => "pay-q",
               "original_group_id" => "group-92",
               "recorded_cents" => 4_000,
               "held_cents" => 4_000,
               "refunded_cents" => 0,
               "retained_cents" => 0,
               "converted_to_credit_cents" => 0,
               "reduced_cents" => 0,
               "charged_back_cents" => 0
             }

      assert [%{"status" => "applied"}] =
               run_batch(conn, [
                 transfer(%{
                   "source_group_id" => "group-92",
                   "destination_group_id" => "group-81",
                   "amount_cents" => 1_000
                 })
               ])

      assert fetch_payment(conn, "pay-q")["held_by_group"] == [
               %{"group_id" => "group-81", "amount_cents" => 1_000},
               %{"group_id" => "group-92", "amount_cents" => 3_000}
             ]

      run_batch(conn, [
        pay("group-81", 100, %{"occurred_on" => "2026-11-02", "operation_id" => "pay-r"})
      ])

      assert fetch_payment(conn, "pay-r")["held_by_group"] == nil

      run_batch(conn, [
        reduce("pay-q", 1_000, %{"operation_id" => "op-red-q-one"}),
        reduce("pay-q", 3_000, %{"operation_id" => "op-red-q-all"})
      ])

      statement = fetch_payment(conn, "pay-q")
      assert statement["held_cents"] == 0
      assert statement["held_by_group"] == []

      # A payment that never participated keeps the earlier shape even when
      # its money is gone.
      run_batch(conn, [reduce("pay-r", 100, %{"operation_id" => "op-red-r"})])

      refute Map.has_key?(fetch_payment(conn, "pay-r"), "held_by_group")
    end
  end

  ## Durability

  describe "idempotency" do
    test "an identical retry replays the stored result without moving funding again", %{
      conn: conn
    } do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 10_000)
      ])

      operation = transfer()
      [%{} = first] = run_batch(conn, [operation])
      before = snapshot(conn)

      assert hd(run_batch(conn, [operation])) == first
      assert snapshot(conn) == before
      assert fetch_operation(conn, "op-transfer") == first
    end

    test "two identical transfers inside one batch move funding once", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 10_000)
      ])

      assert [
               %{"status" => "applied"} = first,
               second
             ] =
               run_batch(conn, [
                 transfer(%{"operation_id" => "op-tx-dup"}),
                 transfer(%{"operation_id" => "op-tx-dup"})
               ])

      assert second == first
      assert fetch_group(conn, "group-92")["cash_paid_cents"] == 3_000
      assert fetch_group(conn, "group-92")["revision"] == 2
    end

    test "reusing the identifier with a different payload conflicts", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 10_000)
      ])

      [%{} = applied] = run_batch(conn, [transfer(%{"amount_cents" => 1_000})])

      assert [%{"status" => "rejected", "code" => "operation_id_conflict"}] =
               run_batch(conn, [transfer(%{"amount_cents" => 2_000})])

      assert fetch_operation(conn, "op-transfer") == applied
      assert fetch_group(conn, "group-92")["cash_paid_cents"] == 1_000
    end

    test "an operation without a usable identifier is rejected like every other", %{conn: conn} do
      run_batch(conn, [
        open_operation(),
        open_destination(),
        pay("group-81", 10_000)
      ])

      assert [%{"operation_id" => nil, "status" => "rejected", "code" => "invalid_operation"}] =
               run_batch(conn, [transfer(%{"operation_id" => nil})])

      assert fetch_group(conn, "group-92")["cash_paid_cents"] == 0
      assert fetch_group(conn, "group-92")["revision"] == 1
    end
  end

  defp assert_ledger(conn, expectations) do
    assert fetch_ledger(conn) ==
             Map.merge(
               %{
                 "cash_held_cents" => 0,
                 "cash_refunded_cents" => 0,
                 "cash_retained_cents" => 0,
                 "cash_converted_to_credit_cents" => 0,
                 "cash_reduced_cents" => 0,
                 "cash_charged_back_cents" => 0,
                 "credit_liability_cents" => 0,
                 "credit_shortfall_cents" => 0
               },
               Map.new(expectations, fn {k, v} -> {Atom.to_string(k), v} end)
             )
  end
end
