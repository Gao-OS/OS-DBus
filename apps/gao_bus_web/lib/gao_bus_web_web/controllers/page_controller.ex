defmodule GaoBusWebWeb.PageController do
  use GaoBusWebWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
