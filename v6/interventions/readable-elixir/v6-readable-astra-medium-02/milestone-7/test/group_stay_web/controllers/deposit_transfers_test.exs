defmodule GroupStayWeb.DepositTransfersTest do
  use GroupStayWeb.ConnCase, async: false
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, CashAllocation, CreditAllocation, CreditLot}

  defp op(type, id, fields) do
    Map.merge(%{"type" => type, "operation_id" => id, "occurred_on" => "2027-01-01"}, fields)
  end

  defp open(id, fields \\ %{}) do
    op(
      "open_group",
      "open-" <> id,
      Map.merge(
        %{
          "group_id" => id,
          "guest_id" => "guest",
          "property_id" => id,
          "arrival_on" => "2027-06-01",
          "departure_on" => "2027-06-02",
          "rate_plan" => "flexible",
          "rooms" => for(id <- ~w(a b c), do: %{"room_id" => id, "nightly_rate_cents" => 500})
        },
        fields
      )
    )
  end

  defp pay(id, group, amount),
    do: op("record_cash_payment", id, %{"group_id" => group, "amount_cents" => amount})

  defp credit(id, group, amount),
    do: op("apply_hotel_credit", id, %{"group_id" => group, "amount_cents" => amount})

  defp transfer(id, source, destination, amount, fields \\ %{}),
    do:
      op(
        "transfer_deposit",
        id,
        Map.merge(
          %{
            "source_group_id" => source,
            "destination_group_id" => destination,
            "amount_cents" => amount
          },
          fields
        )
      )

  defp cancel(id, group, fields \\ %{}),
    do: op("cancel_group", id, Map.put(fields, "group_id", group))

  defp correction(type, id, payment, fields \\ %{}),
    do: op(type, id, Map.put(fields, "payment_operation_id", payment))

  defp batch(ops),
    do:
      build_conn()
      |> post("/api/v1/partner-batches", %{"operations" => ops})
      |> json_response(200)
      |> Map.fetch!("results")

  defp read(path),
    do: build_conn() |> get("/api/v1/" <> path) |> json_response(200) |> Map.fetch!("data")

  defp group(id), do: read("groups/" <> id)
  defp ledger, do: read("ledger?on=2027-01-01")

  defp balances(id),
    do: Enum.map(group(id)["rooms"], &{&1["cash_paid_cents"], &1["credit_paid_cents"]})

  defp snapshot, do: Enum.map([Group, CashAllocation, CreditAllocation, CreditLot], &Repo.all/1)

  defp seed_credit do
    batch([
      open("credit-source"),
      pay("seed", "credit-source", 100),
      cancel("issue", "credit-source", %{"refund_method" => "hotel_credit"})
    ])
  end

  test "mixed funding unwinds global creation order and fills destination in draw order" do
    seed_credit()
    batch([open("s"), open("d"), pay("p1", "s", 150), credit("c", "s", 80), pay("p2", "s", 70)])
    before = ledger()

    request =
      transfer("t", "s", "d", 160, %{
        "expected_revision" => 4,
        "destination_expected_revision" => 1
      })

    assert [result] = batch([request])

    assert result == %{
             "operation_id" => "t",
             "status" => "applied",
             "source_group_id" => "s",
             "destination_group_id" => "d",
             "amount_cents" => 160,
             "source_outstanding_deposit_cents" => 160,
             "destination_outstanding_deposit_cents" => 140,
             "source_revision" => 5,
             "destination_revision" => 2
           }

    assert balances("s") == [{100, 0}, {40, 0}, {0, 0}]
    assert balances("d") == [{70, 30}, {10, 50}, {0, 0}]
    assert ledger() == before

    assert read("payments/p1")["held_by_group"] == [
             %{"group_id" => "d", "amount_cents" => 10},
             %{"group_id" => "s", "amount_cents" => 140}
           ]

    state = snapshot()
    assert [^result] = batch([request])
    assert snapshot() == state
    assert [%{"code" => "operation_id_conflict"}] = batch([Map.put(request, "amount_cents", 1)])
    assert snapshot() == state

    # Returned funding is new funding, so it is drawn before older source slices.
    batch([transfer("back", "d", "s", 60), transfer("again", "s", "d", 10)])
    assert balances("s") == [{100, 0}, {50, 40}, {0, 0}]
    assert balances("d") == [{70, 30}, {0, 10}, {0, 0}]
  end

  test "corrections follow a payment across groups, including an empty original group" do
    payment = pay("p", "s", 250)
    [_, _, _, original] = batch([open("s"), open("b"), open("a"), payment])
    batch([transfer("t1", "s", "b", 150), transfer("t2", "b", "a", 60)])

    assert [%{"revision" => 4, "outstanding_deposit_cents" => 200}] =
             batch([
               correction("reduce_cash_payment", "r", "p", %{
                 "amount_cents" => 80,
                 "expected_revision" => 3
               })
             ])

    assert balances("a") == [{0, 0}, {0, 0}, {0, 0}]
    assert balances("b") == [{70, 0}, {0, 0}, {0, 0}]
    assert group("a")["revision"] == 3
    assert group("b")["revision"] == 4

    assert read("payments/p")["held_by_group"] == [
             %{"group_id" => "b", "amount_cents" => 70},
             %{"group_id" => "s", "amount_cents" => 100}
           ]

    batch([cancel("cancel-s", "s")])

    assert [%{"revision" => 6, "charged_back_cents" => 170}] =
             batch([correction("charge_back_payment", "cb", "p", %{"expected_revision" => 5})])

    assert group("b")["revision"] == 5
    assert group("a")["revision"] == 3
    assert read("payments/p")["held_by_group"] == []
    assert read("payments/p")["reduced_cents"] == 80
    assert ledger()["cash_charged_back_cents"] == 170
    assert [^original] = batch([payment])
  end

  test "validation order, durable rejections, and batch continuation" do
    batch([open("s"), open("d"), open("other", %{"guest_id" => "other"}), pay("p", "s", 100)])
    before = snapshot()

    cases = [
      {transfer("missing-s", "missing", "absent", 0),
       %{"code" => "group_not_found", "group_id" => "missing"}},
      {transfer("missing-d", "s", "absent", 0, %{"expected_revision" => 0}),
       %{"code" => "group_not_found", "group_id" => "absent"}},
      {transfer("stale-s", "s", "d", 0, %{
         "expected_revision" => 0,
         "destination_expected_revision" => 0
       }), %{"code" => "stale_revision", "group_id" => "s", "actual_revision" => 2}},
      {transfer("stale-d", "s", "d", 0, %{
         "expected_revision" => 2,
         "destination_expected_revision" => 0
       }),
       %{
         "code" => "stale_revision",
         "group_id" => "d",
         "expected_revision" => 0,
         "actual_revision" => 1
       }},
      {transfer("same", "s", "s", 10), %{"code" => "invalid_transfer"}},
      {transfer("guest", "s", "other", 10), %{"code" => "invalid_transfer"}},
      {transfer("held", "s", "d", 101), %{"code" => "transfer_exceeds_held_funding"}}
    ]

    for {request, expected} <- cases do
      assert [result] = batch([request])
      assert Map.take(result, Map.keys(expected)) == expected
      assert snapshot() == before
    end

    for {amount, index} <- Enum.with_index([0, -1, nil, "1", 1.5]) do
      assert [%{"code" => "invalid_amount"}] =
               batch([transfer("amount-#{index}", "s", "d", amount)])

      assert snapshot() == before
    end

    for field <- ~w(source_group_id destination_group_id amount_cents) do
      assert [%{"code" => "invalid_operation"}] =
               batch([transfer("missing-" <> field, "s", "d", 1) |> Map.delete(field)])
    end

    batch([pay("full", "d", 300)])

    assert [%{"code" => "transfer_exceeds_outstanding"}] =
             batch([transfer("full-destination", "s", "d", 1)])

    batch([cancel("done", "d")])

    assert [
             %{"code" => "group_not_active", "group_id" => "d"},
             %{"code" => "group_not_active", "group_id" => "d"},
             %{"status" => "applied"}
           ] =
             batch([
               transfer("inactive-d", "s", "d", 1),
               transfer("inactive-s", "d", "s", 1),
               open("new")
             ])

    assert [%{"status" => "applied"}, %{"code" => "stale_revision", "actual_revision" => 1}] =
             batch([
               transfer("valid", "s", "new", 10),
               elem(Enum.at(cases, 3), 0)
             ])
  end

  test "destination policy settles transferred cash and chargeback revokes its credit" do
    batch([
      open("s", %{"rate_plan" => "advance_purchase"}),
      open("d"),
      pay("p", "s", 100),
      transfer("t", "s", "d", 100)
    ])

    assert [%{"credit_issued_cents" => 110}] =
             batch([cancel("convert", "d", %{"refund_method" => "hotel_credit"})])

    assert read("payments/p")["converted_to_credit_cents"] == 100
    assert read("payments/p")["held_by_group"] == []

    batch([
      open("use"),
      credit("use-credit", "use", 100),
      transfer("credit-transfer", "use", "s", 100)
    ])

    source_before = group("s")["revision"]
    batch([correction("charge_back_payment", "cb", "p")])
    assert group("s")["revision"] == source_before + 1
    assert ledger()["credit_shortfall_cents"] == 100
    batch([cancel("consume", "s")])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 0
  end

  test "conversion entitlements use the destination's transferred funding order" do
    batch([
      open("s"),
      open("d"),
      pay("first", "s", 5),
      pay("second", "s", 5),
      transfer("t", "s", "d", 10),
      cancel("lot", "d", %{"refund_method" => "hotel_credit"})
    ])

    assert ledger()["credit_liability_cents"] == 11
    batch([correction("charge_back_payment", "cb", "second")])
    assert ledger()["credit_liability_cents"] == 5
    assert read("payments/second")["charged_back_cents"] == 5
  end

  test "room cancellation settles transferred cash under each destination policy" do
    batch([
      open("s"),
      open("refundable"),
      open("retained", %{"rate_plan" => "advance_purchase"}),
      pay("p", "s", 250),
      transfer("t1", "s", "refundable", 100),
      transfer("t2", "s", "retained", 100)
    ])

    batch([
      op("cancel_rooms", "room", %{"group_id" => "refundable", "room_ids" => ["a"]}),
      cancel("nonrefundable", "retained")
    ])

    assert %{
             "held_cents" => 50,
             "refunded_cents" => 100,
             "retained_cents" => 100,
             "held_by_group" => [%{"group_id" => "s", "amount_cents" => 50}]
           } = read("payments/p")

    assert balances("refundable") == [{0, 0}, {0, 0}, {0, 0}]
    assert group("refundable")["deposit_due_cents"] == 200
  end

  test "returning transferred credit absorbs shortfall and restores only the excess to its original lot" do
    batch([
      open("issuer"),
      pay("p1", "issuer", 50),
      pay("p2", "issuer", 50),
      cancel("lot", "issuer", %{"refund_method" => "hotel_credit"}),
      open("s"),
      open("d"),
      credit("c", "s", 100),
      transfer("t", "s", "d", 100)
    ])

    before = group("d")
    batch([correction("charge_back_payment", "cb", "p1")])
    assert group("d") == before
    assert ledger()["credit_shortfall_cents"] == 45
    batch([cancel("restore", "d", %{"refund_method" => "hotel_credit"})])
    assert ledger()["credit_shortfall_cents"] == 0
    assert ledger()["credit_liability_cents"] == 55

    assert read("guests/guest/credit?on=2027-01-01")["lots"] == [
             %{
               "source_operation_id" => "lot",
               "remaining_cents" => 55,
               "expires_on" => "2028-01-01"
             }
           ]
  end

  test "transferred applied credit stays live past expiry then restores without another bonus" do
    seed_credit()

    batch([
      open("s"),
      open("d", %{"arrival_on" => "2029-06-01", "departure_on" => "2029-06-02"}),
      credit("c", "s", 100)
    ])

    before = read("ledger?on=2028-01-02")
    batch([transfer("t", "s", "d", 100, %{"occurred_on" => "2028-01-02"})])
    assert read("ledger?on=2028-01-02") == before

    assert [%{"credit_issued_cents" => 0, "refunded_cents" => 0}] =
             batch([
               cancel("restore", "d", %{
                 "occurred_on" => "2028-01-02",
                 "refund_method" => "hotel_credit"
               })
             ])

    assert read("ledger?on=2028-01-02")["credit_liability_cents"] == 0
    refute Map.has_key?(read("payments/seed"), "held_by_group")
  end
end
