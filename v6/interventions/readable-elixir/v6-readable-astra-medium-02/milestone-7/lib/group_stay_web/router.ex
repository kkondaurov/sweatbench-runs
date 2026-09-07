defmodule GroupStayWeb.Router do
  use GroupStayWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api/v1", GroupStayWeb do
    pipe_through :api

    post "/partner-batches", PartnerController, :create
    get "/groups/:group_id", PartnerController, :show
    get "/guests/:guest_id/credit", PartnerController, :credit
    get "/operations/:operation_id", PartnerController, :operation
    get "/payments/:payment_operation_id", PartnerController, :payment
    get "/finance/daily-report", PartnerController, :daily_report
    get "/ledger", PartnerController, :ledger
  end
end
