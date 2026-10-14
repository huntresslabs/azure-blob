# frozen_string_literal: true

require "securerandom"

module AzureBlob
  # Builds and parses {Blob Batch}[https://learn.microsoft.com/en-us/rest/api/storageservices/blob-batch]
  # requests. The parent request succeeds whenever the batch parses; each
  # subrequest reports its own status in the multipart response body.
  class BlobBatch # :nodoc:
    MAX_SUBREQUESTS = 256
    CRLF = "\r\n"

    Failure = Struct.new(:key, :status, :error_code)

    attr_reader :boundary

    def initialize(keys, signer:)
      raise ArgumentError, "at most #{MAX_SUBREQUESTS} keys per batch" if keys.size > MAX_SUBREQUESTS

      @keys = keys
      @signer = signer
      @boundary = "batch_#{SecureRandom.uuid}"
    end

    def content_type
      "multipart/mixed; boundary=#{boundary}"
    end

    # Returns the multipart body with one signed DELETE subrequest per key.
    # +uri_for+ maps a key to its blob URI.
    def delete_body(&uri_for)
      date = Time.now.httpdate

      keys.each_with_index.map do |key, index|
        [
          "--#{boundary}",
          "Content-Type: application/http",
          "Content-Transfer-Encoding: binary",
          "Content-ID: #{index}",
          "",
          *delete_subrequest(uri_for.call(key), date),
          "",
        ].join(CRLF)
      end.join(CRLF) + "#{CRLF}--#{boundary}--#{CRLF}"
    end

    # Returns a Failure for every key whose subresponse was missing or not 2xx.
    def failures(response_body)
      results = parse_results(response_body)

      keys.each_with_index.filter_map do |key, index|
        status, error_code = results[index]

        if status.nil?
          Failure.new(key, nil, "MalformedBatchResponse")
        elsif !status.to_s.start_with?("2")
          Failure.new(key, status, error_code)
        end
      end
    end

    private

    attr_reader :keys, :signer

    def delete_subrequest(uri, date)
      headers = { "x-ms-date": date, "x-ms-delete-snapshots": "include", "Content-Length": "0" }
      authorization = signer.authorization_header(uri:, verb: "DELETE", headers:)

      [
        "DELETE #{uri.request_uri} HTTP/1.1",
        *headers.map { |name, value| "#{name}: #{value}" },
        "Authorization: #{authorization}",
        "",
      ]
    end

    def parse_results(response_body)
      response_boundary = response_body[/\A--(\S+)/, 1]
      return {} if response_boundary.nil?

      response_body.split("--#{response_boundary}").each_with_object({}) do |part, results|
        index = part[/^Content-ID:\s*(\d+)/i, 1]
        status = part[%r{^HTTP/1\.1 (\d{3})}, 1]
        next if index.nil? || status.nil?

        results[index.to_i] = [ status.to_i, part[%r{<Code>([^<]+)</Code>}, 1] ]
      end
    end
  end
end
