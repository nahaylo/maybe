require "test_helper"

class DumpFormTest < ActionDispatch::IntegrationTest
  test "dump" do
    sign_in users(:family_admin)
    get new_transfer_url
    html = response.body
    idx = html.index("destination_amount")
    puts "---- rendered destination block ----"
    puts html[(idx - 500)..(idx + 400)]
  end
end
