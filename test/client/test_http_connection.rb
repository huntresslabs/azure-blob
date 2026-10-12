# frozen_string_literal: true

require_relative "test_helper"

class TestHttpConnection < TestCase
  class FakeConnection
    attr_reader :calls

    def initialize(status: "200", body: "")
      @status = status
      @body = body
      @calls = []
    end

    def request(uri, request, &block)
      @calls << [ uri, request ]
      response = Net::HTTPResponse::CODE_TO_OBJ[@status].new("1.1", @status, "")
      response.instance_variable_set(:@body, @body)
      response.instance_variable_set(:@read, true)
      block&.call(response)
      response
    end
  end

  def setup
    @uri = URI("https://account.blob.core.windows.net/container/key")
  end

  def test_requests_go_through_the_connection_instead_of_a_fresh_net_http
    connection = FakeConnection.new(body: "payload")
    http = AzureBlob::Http.new(@uri, { "x-ms-blob-type": "BlockBlob" }, connection:)

    assert_nil http.instance_variable_get(:@http)
    assert_equal "payload", http.get

    uri, request = connection.calls.fetch(0)
    assert_equal @uri, uri
    assert_instance_of Net::HTTP::Get, request
    assert_equal "/container/key", request.path
    assert_equal "BlockBlob", request["x-ms-blob-type"]
    assert_equal AzureBlob::API_VERSION, request["x-ms-version"]
  end

  def test_each_verb_builds_the_matching_request_and_body
    connection = FakeConnection.new
    AzureBlob::Http.new(@uri, connection:).put("content")
    AzureBlob::Http.new(@uri, connection:).post("form")
    AzureBlob::Http.new(@uri, connection:).head
    AzureBlob::Http.new(@uri, connection:).delete

    requests = connection.calls.map(&:last)
    assert_equal [ Net::HTTP::Put, Net::HTTP::Post, Net::HTTP::Head, Net::HTTP::Delete ], requests.map(&:class)
    assert_equal [ "content", "form", nil, nil ], requests.map(&:body)
  end

  def test_io_bodies_are_streamed_instead_of_assigned_as_body
    connection = FakeConnection.new
    io = StringIO.new("streamed")

    AzureBlob::Http.new(@uri, connection:).put(io)

    request = connection.calls.fetch(0).last
    assert_nil request.body
    assert_same io, request.body_stream
  end

  def test_streams_the_response_through_the_block
    connection = FakeConnection.new(body: "chunk")
    yielded = nil

    AzureBlob::Http.new(@uri, connection:).get_full_response { |response| yielded = response }

    assert_equal "chunk", yielded.body
  end

  def test_errors_are_still_mapped_from_the_response
    connection = FakeConnection.new(status: "404", body: "<Error><Code>BlobNotFound</Code></Error>")

    assert_raises(AzureBlob::Http::FileNotFoundError) do
      AzureBlob::Http.new(@uri, connection:).get
    end
  end

  def test_client_threads_the_connection_into_every_request
    connection = FakeConnection.new
    client = AzureBlob::Client.new(account_name: "account", access_key: Base64.strict_encode64("secret"), container: "container", connection:)

    client.delete_blob("key")
    client.get_blob_properties("key")

    assert_equal 2, connection.calls.size
    assert_equal [ Net::HTTP::Delete, Net::HTTP::Head ], connection.calls.map { |_, request| request.class }
  end
end
