require 'json'
require 'msgpack'

module Datadog
  # Encoding module that encodes data for the AgentTransport
  module Encoding
    # Encoder interface that provides the logic to encode traces and service
    module Encoder
      def content_type
        raise NotImplementedError
      end

      # Trace agent limit payload size of 10 MiB (since agent v5.11.0):
      # https://github.com/DataDog/datadog-agent/blob/6.14.1/pkg/trace/api/api.go#L46
      #
      # We set the value to a conservative 5 MiB, in case network speed is slow.
      DEFAULT_MAX_PAYLOAD_SIZE = 5 * 1024 * 1024

      # Encodes a list of traces in batches, expecting a list of items where each items
      # is a list of spans.
      # A serialized batch payload will not exceed +max_size+.
      # Single traces larger than +max_size+ will be discarded.
      # Before serializing, all traces are normalized. Trace nesting is not changed.
      #
      # @param traces [Array<Trace>] list of traces
      # @param max_size [String] maximum acceptable payload size
      # @yield [encoded_batch, batch_size] block invoked for every serialized batch of traces
      # @yieldparam encoded_batch [String] serialized batch of traces, ready to be transmitted
      # @yieldparam batch_size [Integer] number of traces serialized in this batch
      # @return concatenated list of return values from the provided block
      def encode_traces(traces, max_size: DEFAULT_MAX_PAYLOAD_SIZE)
        # Captures all return values from the provided block
        returns = []

        encoded_batch = []
        batch_size = 0
        traces.each do |trace|
          encoded_trace = encode_one(trace, max_size)

          next unless encoded_trace

          if encoded_trace.size + batch_size > max_size
            # Can't fit trace in current batch
            # TODO Datadog::Debug::HealthMetrics.increment('tracer.encoder.batch.chunked')

            # Flush current batch
            returns << yield(join(encoded_batch), encoded_batch.size)
            # TODO: Datadog::Debug::HealthMetrics.increment('tracer.encoder.batch.yield')

            # Create new batch
            encoded_batch = []
            batch_size = 0
          end

          encoded_batch << encoded_trace
          batch_size += encoded_trace.size
        end

        unless encoded_batch.empty?
          returns << yield(join(encoded_batch), encoded_batch.size)
          # TODO: Datadog::Debug::HealthMetrics.increment('tracer.encoder.batch.yield')
        end

        returns
      end

      private

      def encode_one(trace, max_size)
        encoded = encode(trace.map(&:to_hash))

        # TODO: Datadog::Debug::HealthMetrics.increment('tracer.encoder.trace.encode')
        if encoded.size > max_size
          # This single trace is too large, we can't flush it
          Datadog::Tracer.log.debug { "Trace payload too large: #{trace.to_hash}" }
          return nil
        end

        encoded
      end

      # Concatenates a list of traces previously encoded by +#encode+.
      def join(encoded_traces)
        raise NotImplementedError
      end

      # Serializes a single trace into a String suitable for network transmission.
      def encode(_)
        raise NotImplementedError
      end
    end

    # Encoder for the JSON format
    module JSONEncoder
      extend Encoder

      CONTENT_TYPE = 'application/json'.freeze

      module_function

      def content_type
        CONTENT_TYPE
      end

      def encode(trace)
        JSON.dump(trace)
      end

      def join(encoded_traces)
        "[#{encoded_traces.join(',')}]"
      end
    end

    # Encoder for the Msgpack format
    module MsgpackEncoder
      extend Encoder

      module_function

      CONTENT_TYPE = 'application/msgpack'.freeze

      def content_type
        CONTENT_TYPE
      end

      def encode(trace)
        MessagePack.pack(trace)
      end

      def join(encoded_traces)
        packer = MessagePack::Packer.new
        packer.write_array_header(encoded_traces.size)

        (packer.to_a + encoded_traces).join
      end
    end
  end
end
