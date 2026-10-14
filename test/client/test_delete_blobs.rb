# frozen_string_literal: true

require_relative "test_helper"
require_relative "test_http_connection"
require "base64"

class TestDeleteBlobs < TestCase
  FakeConnection = TestHttpConnection::FakeConnection

  def setup
    @account = "account"
    @container = "container"
    @keys = [ "a/b c.json", "d.json" ]
  end

  def client(connection)
    AzureBlob::Client.new(
      account_name: @account,
      access_key: Base64.strict_encode64("key"),
      container: @container,
      connection:,
    )
  end

  def batch_response(parts)
    boundary = "batchresponse_x"
    body = parts.map do |content_id, status, error_code|
      error = error_code ? "<?xml version=\"1.0\" encoding=\"utf-8\"?><Error><Code>#{error_code}</Code><Message>nope</Message></Error>" : ""
      id_header = content_id ? "Content-ID: #{content_id}\r\n" : ""
      "--#{boundary}\r\nContent-Type: application/http\r\n#{id_header}\r\nHTTP/1.1 #{status}\r\nContent-Length: #{error.bytesize}\r\n\r\n#{error}\r\n"
    end.join
    "#{body}--#{boundary}--\r\n"
  end

  def test_posts_one_multipart_batch_with_a_signed_delete_subrequest_per_key
    connection = FakeConnection.new(status: "202", body: batch_response([ [ 0, "202 Accepted" ], [ 1, "202 Accepted" ] ]))

    assert_empty client(connection).delete_blobs(@keys)

    uri, request = connection.calls.fetch(0)
    assert_equal 1, connection.calls.size
    assert_instance_of Net::HTTP::Post, request
    assert_equal "/#{@container}?restype=container&comp=batch", uri.request_uri
    assert_equal request.body.bytesize.to_s, request["Content-Length"]
    assert_match(/\ASharedKey #{@account}:/, request["Authorization"])
    assert_equal AzureBlob::API_VERSION, request["x-ms-version"]

    boundary = request["Content-Type"][/\Amultipart\/mixed; boundary=(batch_\S+)\z/, 1]
    refute_nil boundary
    subrequests = request.body.split("--#{boundary}")[1..-2]
    assert_equal 2, subrequests.size
    assert_includes subrequests[0], "Content-ID: 0\r\n"
    assert_includes subrequests[0], "DELETE /#{@container}/a/b%20c.json HTTP/1.1\r\n"
    assert_includes subrequests[0], "x-ms-delete-snapshots: include\r\n"
    assert_match(/Authorization: SharedKey #{@account}:/, subrequests[0])
    assert_includes subrequests[1], "Content-ID: 1\r\n"
    assert_includes subrequests[1], "DELETE /#{@container}/d.json HTTP/1.1\r\n"
    refute_includes subrequests.join, "x-ms-version"
    assert request.body.end_with?("\r\n--#{boundary}--\r\n")
  end

  def test_returns_failed_subrequests_with_status_and_error_code
    connection = FakeConnection.new(status: "202", body: batch_response([ [ 0, "404 The specified blob does not exist.", "BlobNotFound" ], [ 1, "503 Server busy", "ServerBusy" ] ]))

    failures = client(connection).delete_blobs(@keys).map(&:to_a)

    assert_equal [ [ "a/b c.json", 404, "BlobNotFound" ], [ "d.json", 503, "ServerBusy" ] ], failures
  end

  def test_keys_without_a_subresponse_are_failures
    connection = FakeConnection.new(status: "202", body: batch_response([ [ 0, "202 Accepted" ] ]))

    assert_equal [ [ "d.json", nil, "MalformedBatchResponse" ] ], client(connection).delete_blobs(@keys).map(&:to_a)
  end

  def test_subresponses_without_a_content_id_are_failures
    connection = FakeConnection.new(status: "202", body: batch_response([ [ 1, "202 Accepted" ], [ nil, "400 One of the request inputs is not valid.", "InvalidInput" ] ]))

    assert_equal [ [ "a/b c.json", nil, "MalformedBatchResponse" ] ], client(connection).delete_blobs(@keys).map(&:to_a)
  end

  def test_non_multipart_responses_fail_every_key
    connection = FakeConnection.new(status: "202", body: "")

    assert_equal [ [ "a/b c.json", nil, "MalformedBatchResponse" ], [ "d.json", nil, "MalformedBatchResponse" ] ], client(connection).delete_blobs(@keys).map(&:to_a)
  end

  def test_parent_request_errors_raise
    connection = FakeConnection.new(status: "403", body: "<Error><Code>AuthenticationFailed</Code></Error>")

    assert_raises(AzureBlob::Http::ForbiddenError) { client(connection).delete_blobs(@keys) }
  end

  def test_rejects_more_keys_than_one_batch_allows
    keys = Array.new(AzureBlob::BlobBatch::MAX_SUBREQUESTS + 1) { |i| "#{i}.json" }

    assert_raises(ArgumentError) { client(FakeConnection.new).delete_blobs(keys) }
  end
end
