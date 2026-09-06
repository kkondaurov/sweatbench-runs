defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", GroupStayWeb do
    pipe_through :api

    scope "/v1" do
      post "/partner-batches", PartnerBatchController, :create
      get "/groups/:group_id", GroupController, :show
      get "/operations/:operation_id", OperationController, :show
      get "/payments/:payment_operation_id", PaymentController, :show
      get "/guests/:guest_id/credit", CreditController, :show
      get "/ledger", LedgerController, :show
      get "/finance/daily-report", FinanceController, :daily_report
    end
  end
end
