require 'vcr/util/version_checker'
require 'vcr/request_handler'
require 'excon'

VCR::VersionChecker.new('Excon', Excon::VERSION, '0.9.6', '0.11').check_version!

module VCR
  class LibraryHooks
    # @private
    module Excon
      class RequestHandler < ::VCR::RequestHandler
        attr_reader :params
        def initialize(params)
          @vcr_response = nil
          @params = params
        end

        def handle
          super
        ensure
          invoke_after_request_hook(@vcr_response)
        end

      private

        def on_stubbed_request
          @vcr_response = stubbed_response
          {
            :body     => stubbed_response.body,
            :headers  => normalized_headers(stubbed_response.headers || {}),
            :status   => stubbed_response.status.code
          }
        end

        def on_ignored_request
          perform_real_request
        end

        def response_from_excon_error(error)
          if error.respond_to?(:response)
            error.response
          elsif error.respond_to?(:socket_error)
            response_from_excon_error(error.socket_error)
          else
            warn "WARNING: VCR could not extract a response from Excon error (#{error.inspect})"
          end
        end

        def real_request_params
          # Excon supports a variety of options that affect how it handles failure
          # and retry; we don't want to use any options here--we just want to get
          # a raw response, and then the main request (with :mock => true) can
          # handle failure/retry on its own with its set options.
          params.merge(:mock => false, :retry_limit => 0).tap do |p|
            [:expects, :idempotent, :instrumentor_name, :instrumentor, :response_block, :request_block].each do |key|
              p.delete(key)
            end
          end
        end

        def perform_real_request
          begin
            response = ::Excon.new(uri).request(real_request_params)
          rescue ::Excon::Errors::Error => excon_error
            response = response_from_excon_error(excon_error)
          end

          @vcr_response = vcr_response_from(response)
          yield response if block_given?
          raise excon_error if excon_error

          response.attributes
        end

        def on_recordable_request
          perform_real_request do |response|
            http_interaction = http_interaction_for(response)
            VCR.record_http_interaction(http_interaction)
          end
        end

        def uri
          @uri ||= "#{params[:scheme]}://#{params[:host]}:#{params[:port]}#{params[:path]}#{query}"
        end

        # based on:
        # https://github.com/geemus/excon/blob/v0.7.8/lib/excon/connection.rb#L117-132
        def query
          @query ||= case params[:query]
            when String
              "?#{params[:query]}"
            when Hash
              qry = '?'
              for key, values in params[:query]
                if values.nil?
                  qry << key.to_s << '&'
                else
                  for value in [*values]
                    qry << key.to_s << '=' << CGI.escape(value.to_s) << '&'
                  end
                end
              end
              qry.chop! # remove trailing '&'
            else
              ''
          end
        end

        def http_interaction_for(response)
          VCR::HTTPInteraction.new \
            vcr_request,
            vcr_response_from(response)
        end

        def vcr_request
          @vcr_request ||= begin
            headers = params[:headers].dup
            headers.delete("Host")

            VCR::Request.new \
              params[:method],
              uri,
              params[:body],
              headers
          end
        end

        def vcr_response_from(response)
          VCR::Response.new \
            VCR::ResponseStatus.new(response.status, nil),
            response.headers,
            response.body,
            nil
        end

        def normalized_headers(headers)
          normalized = {}
          headers.each do |k, v|
            v = v.join(', ') if v.respond_to?(:join)
            normalized[k] = v
          end
          normalized
        end

        ::Excon.stub({}) do |params|
          self.new(params).handle
        end
      end

    end
  end
end

Excon.defaults[:mock] = true

VCR.configuration.after_library_hooks_loaded do
  # ensure WebMock's Excon adapter does not conflict with us here
  # (i.e. to double record requests or whatever).
  if defined?(WebMock::HttpLibAdapters::ExconAdapter)
    WebMock::HttpLibAdapters::ExconAdapter.disable!
  end
end

