# frozen_string_literal: true

require_relative "test_helper"

class TestBlobList < TestCase
  def page(blobs, next_marker)
    <<~XML
      <?xml version="1.0" encoding="utf-8"?>
      <EnumerationResults ServiceEndpoint="https://account.blob.core.windows.net/" ContainerName="container">
        <Prefix>logs/</Prefix>
        <Marker />
        <MaxResults>2</MaxResults>
        <Blobs>#{blobs.join}</Blobs>
        <NextMarker>#{next_marker}</NextMarker>
      </EnumerationResults>
    XML
  end

  def blob(name, length)
    <<~XML
      <Blob>
        <Name>#{name}</Name>
        <Properties>
          <Last-Modified>Mon, 10 Nov 2026 01:02:03 GMT</Last-Modified>
          <Etag>0x8DE1234567890AB</Etag>
          <Content-Length>#{length}</Content-Length>
          <Content-Type>application/octet-stream</Content-Type>
          <Content-Encoding />
          <Content-MD5></Content-MD5>
          <BlobType>BlockBlob</BlobType>
        </Properties>
        <OrMetadata />
      </Blob>
    XML
  end

  def pages
    {
      nil => page([ blob("logs/a &amp; b.json", 10), blob("logs/c&lt;d&gt;.json", 0) ], "marker-2"),
      "marker-2" => page([ blob("logs/e.json", 30) ], ""),
    }
  end

  def list(parser)
    requested = []
    fetcher = ->(marker) do
      requested << marker
      pages.fetch(marker)
    end

    [ AzureBlob::BlobList.new(fetcher, parser:).to_a, requested ]
  end

  def test_nokogiri_parser_matches_rexml
    rexml_blobs, rexml_requested = list(:rexml)
    nokogiri_blobs, nokogiri_requested = list(:nokogiri)

    assert_equal rexml_blobs, nokogiri_blobs
    assert_equal rexml_requested, nokogiri_requested
  end

  def test_nokogiri_parser_reads_every_page
    blobs, requested = list(:nokogiri)

    assert_equal [ "logs/a & b.json", "logs/c<d>.json", "logs/e.json" ], blobs.map(&:first)
    assert_equal [ "10", "0", "30" ], blobs.map { |_, properties| properties["Content-Length"] }
    assert_nil blobs.first.last["Content-Encoding"]
    assert_equal [ nil, "marker-2" ], requested
  end

  def test_unknown_parser
    assert_raises(ArgumentError) { AzureBlob::BlobList.new(->(_) { }, parser: :ox) }
  end
end
