require 'addressable/uri'

BASE_URL = ENV["uber_base_url"]

VALID_COMMANDS = %w(ride products get_eta help accept)

# returned when ride isn't requested in the format '{origin} to {destination}'
RIDE_REQUEST_FORMAT_ERROR = <<-STRING
  To request a ride please use the format */uber ride [origin] to [destination]*.
  For best results, specify a city or zip code.
  Ex: */uber ride 1061 Market Street San Francisco to 405 Howard St*
STRING

PRODUCTS_REQUEST_FORMAT_ERROR = <<-STRING
  To see a list of products please use the format */uber products [address]*.
  For best results, specify a city or zip code.
  Ex: */uber products 1061 Market Street San Francisco
STRING

UNKNOWN_COMMAND_ERROR = <<-STRING
  Sorry, we didn't quite catch that command.  Try */uber help* for a list.
STRING

HELP_TEXT = <<-STRING
  Try these commands:
  - ride [origin address] to [destination address]
  - products [address]
  - help
STRING

LOCATION_NOT_FOUND_ERROR = "Please enter a valid address. Be as specific as possible (e.g. include city)."

class UberCommand
  def initialize(bearer_token, user_id, response_url)
    @bearer_token = bearer_token
    @user_id = user_id
    @response_url = response_url
  end

  def run(user_input_string)
    return UNKNOWN_COMMAND_ERROR if user_input_string.blank?
    input = user_input_string.split(" ", 2) # Only split on first space.
    command_name = input.first.downcase

    #is there a reason we need to downcase what will usually be numbers or addresses?
    command_argument = input.second.nil? ? nil : input.second.downcase

    return UNKNOWN_COMMAND_ERROR if invalid_command?(command_name) || command_name.nil?

    response = send(command_name, command_argument)
    # Send back response if command is not valid
    response
  end

  private

  attr_reader :bearer_token

  def get_eta(address)
    # Handle errors if invalid error is entered
    return LOCATION_NOT_FOUND_ERROR if address.nil? || resolve_address(address) == LOCATION_NOT_FOUND_ERROR
    lat, lng = resolve_address(address)
    uri = Addressable::URI.parse("#{BASE_URL}/v1/estimates/time")
    uri.query_values = { 'start_latitude' => lat, 'start_longitude' => lng }

    resource = uri.to_s

    result = RestClient.get(
      resource,
      authorization: bearer_header,
      "Content-Type" => :json,
      accept: 'json'
    )
    return "Sorry, something went wrong on our part" if result.code == 500

    result = JSON.parse(result)
    min_s, max_s = result['times'].minmax { |el1, el2| el1['estimate'] <=> el2['estimate'] }.map { |x| x['estimate'] }
    min_s /= 60
    max_s /= 60
    max_s += 1 if max_s == min_s
    "Your ride will take between #{min_s} to #{max_s} minutes"
  end

  def ride_request_details(request_id)
    uri = Addressable::URI.parse("#{BASE_URL}/v1/requests/#{request_id}")
    uri.query_values = { 'request_id' => request_id }
    resource = uri.to_s

    result = RestClient.get(
      resource,
      authorization: bearer_header,
      "Content-Type" => :json,
      accept: 'json'
    )

    JSON.parse(result)
  end

  def cancel_ride(request_id)
    uri = Addressable::URI.parse("#{BASE_URL}/v1/requests/#{request_id}")
    # uri.query_values = { 'request_id' => request_id }
    resource = uri.to_s

    result = RestClient.delete(
      resource,
      authorization: bearer_header,
      "Content-Type" => :json,
      accept: 'json'
    )

    "Ride Cancelled" if result
  end

  def help(_) # No command argument.
    HELP_TEXT
  end

  def ride(input_str)
    return RIDE_REQUEST_FORMAT_ERROR unless input_str.include?(" to ")

    origin_name, destination_name = input_str.split("to").map(&:strip)
    origin_lat, origin_lng = resolve_address origin_name
    destination_lat, destination_lng = resolve_address destination_name

    product_id = get_default_product_id_for_lat_lng(origin_lat, origin_lng)

    ride_estimate_hash = get_ride_estimate(
      origin_lat,
      origin_lng,
      destination_lat,
      destination_lng,
      product_id
    )

    surge_multiplier = ride_estimate_hash["price"]["surge_multiplier"]
    surge_confirmation_id = ride_estimate_hash["price"]["surge_confirmation_id"]

    ride_attrs = {
      user_id: @user_id,
      start_latitude: origin_lat,
      start_longitude: origin_lng,
      end_latitude: destination_lat,
      end_longitude: destination_lng,
      product_id: product_id
    }

    unless surge_confirmation_id.blank?
      ride_attrs[:surge_confirmation_id] = surge_confirmation_id
      ride_attrs[:surge_multiplier] = surge_multiplier
    end
    ride = Ride.create!(ride_attrs)


    # not sure why these are being treated differently and are requiring
    # different responses.
    if surge_multiplier > 2
      return [
        "#{surge_multiplier}x surge is in effect.",
        "Reply '/uber accept #{surge_multiplier}' to confirm the ride."
      ].join(" ")
    elsif surge_multiplier > 1
      return [
        "#{surge_multiplier}x surge is in effect.",
        "Reply '/uber accept' to confirm the ride."
      ].join(" ")
    else
      ride_response = request_ride!(
        origin_lat,
        origin_lng,
        destination_lat,
        destination_lng,
        product_id
      )
      if ride_response["errors"]
        # "We were not able to request a ride from Uber. Please try again."
        format_response_errors ride_response["errors"]
      else
        ride.update!(request_id: ride_response['request_id'])
        success_msg = format_200_ride_request_response(ride_response)
      end
      # ""
    end
  end

  def accept(stated_multiplier)
    @ride = Ride.where(user_id: @user_id).order(:updated_at).last

    if @ride.nil?
      return "Sorry, we're not sure which ride you want to confirm. Please try requesting another."
    end

    multiplier = @ride.surge_multiplier

    # I'm unclear why we are explicitly requiring them to type the multiplier only when >= 2.
    # A confusing design decision, and probably confusing for the user.
    if multiplier >= 2.0
      if stated_multiplier.nil? || stated_multiplier.to_f != multiplier ||
        !stated_multiplier.include?('.')
        return "That didn't work. Please reply '/uber accept #{multiplier}' to confirm the ride."
      end
    end

    surge_confirmation_id = @ride.surge_confirmation_id
    product_id = @ride.product_id

    start_latitude = @ride.start_latitude
    start_longitude = @ride.start_longitude
    end_latitude = @ride.end_latitude
    end_longitude = @ride.end_longitude

    fail_msg = "Sorry but something went wrong. We were unable to request a ride."

    if (Time.now - @ride.updated_at) > 5.minutes #if surge may have passed since original request
      # TODO: Break out address resolution in #ride so that we can pass lat/lngs directly.
      start_location = "#{start_latitude}, #{start_longitude}"
      end_location = "#{end_latitude}, #{end_longitude}"
      return ride "#{start_location} to #{end_location}"
    else
      begin
        response = request_ride!(
          start_latitude,
          start_longitude,
          end_latitude,
          end_longitude,
          product_id,
          surge_confirmation_id
        )
      rescue
        # at one point some of these messages were changed to send via response_url
        # but without asynchronous requests, there's not much point yet.
        # e.g. RestClient.post(@response_url, fail_msg, "Content-Type" => :json)
        return fail_msg
      end

      if response.code == 200 || response.code == 202
        success_msg = format_200_ride_request_response(JSON.parse(response.body))
      else
        fail_msg
      end
    end
    # ""
  end

  def request_ride!(start_lat, start_lng, end_lat, end_lng, product_id, surge_confirmation_id = nil)
     body = {
       start_latitude: start_lat,
       start_longitude: start_lng,
       end_latitude: end_lat,
       end_longitude: end_lng,
       product_id: product_id
     }

     body['surge_confirmation_id'] = surge_confirmation_id if surge_confirmation_id

     response = RestClient.post(
       "#{BASE_URL}/v1/requests",
       body.to_json,
       authorization: bearer_header,
       "Content-Type" => :json,
       accept: :json
     )

   JSON.parse(response.body)
  end

  def fares input_str
    return RIDE_REQUEST_FORMAT_ERROR unless input_str.include?(" to ")

    origin_name, destination_name = input_str.split("to").map(&:strip)
    origin_lat, origin_lng = resolve_address origin_name
    destination_lat, destination_lng = resolve_address destination_name

    product_id = get_default_product_id_for_lat_lng(origin_lat, origin_lng)
    resp = get_ride_estimate(origin_lat, origin_lng, destination_lat,
      destination_lng, product_id)

    low = resp["price"]["high_estimate"]
    high = resp["price"]["low_estimate"]
    eta = resp["pickup_estimate"]
    if resp["price"]["surge_multiplier"] > 1
      mult = resp["price"]["surge_multiplier"]
      <<-STRING
        #{mult}x surge is in effect.
        Current price estimate is #{low} - #{high}.
        A car would be available in approximately #{eta} minutes.
      STRING
    else
      <<-STRING
        Current price estimate is #{low} - #{high}.
        A car would be available in approximately #{eta} minutes.
      STRING
    end
  end

  def get_ride_estimate(start_lat, start_lng, end_lat, end_lng, product_id)
    body = {
      start_latitude: start_lat,
      start_longitude: start_lng,
      end_latitude: end_lat,
      end_longitude: end_lng,
      product_id: product_id
    }

    response = RestClient.post(
      "#{BASE_URL}/v1/requests/estimate",
      body.to_json,
      authorization: bearer_header,
      "Content-Type" => :json,
      accept: :json
    )

    JSON.parse(response.body)
 end

  def products(address = nil)
    return PRODUCTS_REQUEST_FORMAT_ERROR if address.blank?

    resolved_add = resolve_address(address)

    if resolved_add == LOCATION_NOT_FOUND_ERROR
      LOCATION_NOT_FOUND_ERROR
    else
      lat, lng = resolved_add
      format_products_response(get_products_for_lat_lng lat, lng)
    end
  end

  def get_products_for_lat_lng(lat, lng)
    uri = Addressable::URI.parse("#{BASE_URL}/v1/products")
    uri.query_values = { 'latitude' => lat, 'longitude' => lng }
    resource = uri.to_s

    result = RestClient.get(
      resource,
      authorization: bearer_header,
      "Content-Type" => :json,
      accept: 'json'
    )

    JSON.parse(result.body)
  end

  def format_200_ride_request_response(response)
    eta = response['eta'].to_i / 60

    estimate_msg = "very soon" if eta == 0
    estimate_msg = "in 1 minute" if eta == 1
    estimate_msg = "in #{eta} minutes" if eta > 1

    "Thanks! A driver will be on their way soon. We expect them to arrive #{estimate_msg}."
  end

  def format_response_errors(response_errors)
    response = "The following errors occurred: \n"
    response_errors.each do |error|
      response += "- *#{error['title']}* \n"
    end
  end

  def format_products_response(products_response)
    unless products_response['products'] && !products_response['products'].empty?
      return "No Uber products available for that location."
    end
    response = "The following products are available: \n"
    products_response['products'].each do |product|
      response += "- #{product['display_name']}: #{product['description']} (Capacity: #{product['capacity']})\n"
    end
    response
  end

  def bearer_header
    "Bearer #{bearer_token}"
  end

  def invalid_command?(name)
    !VALID_COMMANDS.include? name
  end

  def resolve_address(address)
    location = Geocoder.search(address).first

    if location.blank?
      LOCATION_NOT_FOUND_ERROR
    else
      location = location.data["geometry"]["location"]
      [location['lat'], location['lng']]
    end
  end
end
