# frozen_string_literal: true

require "rexml"

module AzureBlob
  # Enumerator class to lazily iterate over a list of Blob keys.
  class BlobList
    include REXML
    include Enumerable

    # You should not instanciate this object directly,
    # but obtain one when calling relevant methods of AzureBlob::Client.
    #
    # Expects a callable object that takes an Azure API page marker as an
    # argument and returns the raw body response of a call to the list blob endpoint.
    #
    # Example:
    #
    #   fetcher = ->(marker) do
    #     uri.query = URI.encode_www_form(
    #       marker: marker,
    #       ...
    #     )
    #     response = Http.new(uri, signer:).get
    #   end
    #   AzureBlob::BlobList.new(fetcher)
    #
    def initialize(fetcher, parser: :rexml)
      raise ArgumentError, "unknown parser: #{parser.inspect}" unless %i[rexml nokogiri].include?(parser)

      require "nokogiri" if parser == :nokogiri
      @fetcher = fetcher
      @parser = parser
    end

    def size
      to_a.size
    end

    def each
      loop do
        fetch
        current_page.each do |key, properties|
          yield key, properties
        end

        break unless marker
      end
    end

    def to_s
      to_a.to_s
    end

    def inspect
      to_a.inspect
    end

    def marker
      return initial_marker if document.nil?

      @current_marker
    end

    attr_accessor :initial_marker, :fetched_at

    private

    def current_page
      return nokogiri_page if @parser == :nokogiri

      document.get_elements("//EnumerationResults/Blobs/Blob").map do |element|
        [element.get_elements("Name").first.text,
         element.get_elements("Properties//").to_h { |p| [p.name, p.text] }]
      end
    end

    def nokogiri_page
      document.xpath("/EnumerationResults/Blobs/Blob").map do |element|
        properties = element.at_xpath("Properties")
        nodes = properties ? [ properties, *properties.element_children ] : []
        [ nokogiri_text(element.at_xpath("Name")), nodes.to_h { |p| [ p.name, nokogiri_text(p) ] } ]
      end
    end

    def nokogiri_text(node)
      node.children.find(&:text?)&.content
    end

    def fetch
      @fetched_at = Time.now.utc
      body = fetcher.call(marker)

      if @parser == :nokogiri
        @document = Nokogiri::XML(body) { |config| config.strict }
        next_marker = document.at_xpath("/EnumerationResults/NextMarker")
        @current_marker = next_marker && nokogiri_text(next_marker)
      else
        @document = Document.new(body)
        @current_marker = document.get_elements("//EnumerationResults/NextMarker").first.get_text()&.to_s
      end
    end

    attr_reader :document, :fetcher
  end
end
