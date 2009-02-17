module Nanite
  class << self
    attr_accessor :mapper    
    
    def request(*args, &blk)
      @mapper.request(*args, &blk)
    end

    def push(*args, &blk)
      @mapper.push(*args, &blk)
    end
  end  
  
  # Mappers are control nodes in nanite clusters. Nanite clusters
  # can follow peer-to-peer model of communication as well as client-server,
  # and mappers are nodes that know who to send work requests to agents.
  #
  # Mappers can reside inside a front end web application written in Merb/Rails
  # and distribute heavy lifting to actors that register with the mapper as soon
  # as they go online.
  #
  # Each mapper tracks nanites registered with it. It periodically checks
  # when the last time a certain nanite sent a heartbeat notification,
  # and removes those that have timed out from the list of available workers.
  # As soon as a worker goes back online again it re-registers itself
  # and the mapper adds it to the list and makes it available to
  # be called again.
  #
  # This makes Nanite clusters self-healing and immune to individual node
  # failures.
  class Mapper
    include AMQPHelper
    include ConsoleHelper
    include DaemonizeHelper

    attr_reader :cluster, :identity, :job_warden, :options, :serializer, :log, :amq

    DEFAULT_OPTIONS = COMMON_DEFAULT_OPTIONS.merge({:user => 'mapper', :identity => Identity.generate, :agent_timeout => 15,
      :offline_redelivery_frequency => 10, :persistent => false}) unless defined?(DEFAULT_OPTIONS)

    # Initializes a new mapper and establishes
    # AMQP connection. This must be used inside EM.run block or if EventMachine reactor
    # is already started, for instance, by a Thin server that your Merb/Rails
    # application runs on.
    #
    # Mapper options:
    #
    # identity    : identity of this mapper, may be any string
    #
    # format      : format to use for packets serialization. Can be :marshal, :json or :yaml.
    #               Defaults to Ruby's Marshall format. For interoperability with
    #               AMQP clients implemented in other languages, use JSON.
    #
    #               Note that Nanite uses JSON gem,
    #               and ActiveSupport's JSON encoder may cause clashes
    #               if ActiveSupport is loaded after JSON gem.
    #
    # log_level   : the verbosity of logging, can be debug, info, warn, error or fatal.
    #
    # agent_timeout   : how long to wait before an agent is considered to be offline
    #                   and thus removed from the list of available agents.
    #
    # log_dir    : log file path, defaults to the current working directory.
    #
    # console     : true tells mapper to start interactive console
    #
    # daemonize   : true tells mapper to daemonize
    #
    # offline_redelivery_frequency : The frequency in seconds that messages stored in the offline queue will be retrieved
    #                                for attempted redelivery to the nanites. Default is 10 seconds.
    #
    # persistent  : true instructs the AMQP broker to save messages to persistent storage so that they aren't lost when the
    #               broker is restarted. Default is false. Can be overriden on a per-message basis using the request and push methods.
    # 
    # secure      : use Security features of rabbitmq to restrict nanites to themselves
    #
    # Connection options:
    #
    # vhost    : AMQP broker vhost that should be used
    #
    # user     : AMQP broker user
    #
    # pass     : AMQP broker password
    #
    # host     : host AMQP broker (or node of interest) runs on,
    #            defaults to 0.0.0.0
    #
    # port     : port AMQP broker (or node of interest) runs on,
    #            this defaults to 5672, port used by some widely
    #            used AMQP brokers (RabbitMQ and ZeroMQ)
    #
    # @api :public:
    def self.start(options = {})
      new(options)
    end

    def initialize(options)
      @options = DEFAULT_OPTIONS.merge(options)
      @identity = "mapper-#{@options[:identity]}"
      @log = Log.new(@options, @identity)
      @serializer = Serializer.new(@options[:format])
      daemonize if @options[:daemonize]
      @amq =start_amqp(@options)
      @cluster = Cluster.new(@amq, @options[:agent_timeout], @options[:identity], @log, @serializer)
      @job_warden = JobWarden.new(@serializer, @log)
      @log.info('starting mapper')
      setup_queues
      start_console if @options[:console] && !@options[:daemonize]
    end

    # Make a nanite request which expects a response.
    #
    # ==== Parameters
    # type<String>:: The dispatch route for the request
    # payload<Object>:: Payload to send.  This will get marshalled en route
    #
    # ==== Options
    # :selector<Symbol>:: Method for selecting an actor.  Default is :least_loaded.
    #   :least_loaded:: Pick the nanite which has the lowest load.
    #   :all:: Send the request to all nanites which respond to the service.
    #   :random:: Randomly pick a nanite.
    #   :rr: Select a nanite according to round robin ordering.
    # :target<String>:: Select a specific nanite via identity, rather than using
    #   a selector.
    # :offline_failsafe<Boolean>:: Store messages in an offline queue when all
    #   the nanites are offline. Messages will be redelivered when nanites come online.
    #   Default is false.
    # :persistent<Boolean>:: Instructs the AMQP broker to save the message to persistent
    #   storage so that it isnt lost when the broker is restarted.
    #   Default is false unless the mapper was started with the --persistent flag.
    #
    # ==== Block Parameters
    # :results<Object>:: The returned value from the nanite actor.
    #
    # @api :public:
    def request(type, payload = '', opts = {}, &blk)
      request = build_request(type, payload, opts)
      request.reply_to = identity
      targets = cluster.targets_for(request)
      if !targets.empty?
        job = job_warden.new_job(request, targets, blk)
        cluster.route(request, job.targets)
        job
      elsif opts[:offline_failsafe]
        cluster.publish(request, 'mapper-offline')
        :offline
      end
    end

    # Make a nanite request which does not expect a response.
    #
    # ==== Parameters
    # type<String>:: The dispatch route for the request
    # payload<Object>:: Payload to send.  This will get marshalled en route
    #
    # ==== Options
    # :selector<Symbol>:: Method for selecting an actor.  Default is :least_loaded.
    #   :least_loaded:: Pick the nanite which has the lowest load.
    #   :all:: Send the request to all nanites which respond to the service.
    #   :random:: Randomly pick a nanite.
    #   :rr: Select a nanite according to round robin ordering.
    # :offline_failsafe<Boolean>:: Store messages in an offline queue when all
    #   the nanites are offline. Messages will be redelivered when nanites come online.
    #   Default is false.
    # :persistent<Boolean>:: Instructs the AMQP broker to save the message to persistent
    #   storage so that it isnt lost when the broker is restarted.
    #   Default is false unless the mapper was started with the --persistent flag.
    #
    # @api :public:
    def push(type, payload = '', opts = {})
      request = build_request(type, payload, opts)
      cluster.route(request, cluster.targets_for(request))
      true
    end

    private

    def build_request(type, payload, opts)
      request = Request.new(type, payload, opts)
      request.from = identity
      request.token = Identity.generate
      request.persistent = opts.key?(:persistent) ? opts[:persistent] : options[:persistent]
      request
    end

    def setup_queues
      setup_offline_queue
      setup_message_queue
    end

    def setup_offline_queue
      offline_queue = amq.queue('mapper-offline', :durable => true)
      offline_queue.subscribe(:ack => true) do |info, request|
        request = serializer.load(request)
        request.reply_to = identity
        targets = cluster.targets_for(request)
        unless targets.empty?
          info.ack
          job = job_warden.new_job(request, targets)
          cluster.route(request, job.targets)
        end
      end

      EM.add_periodic_timer(options[:offline_redelivery_frequency]) { offline_queue.recover }
    end

    def setup_message_queue
      amq.queue(identity, :exclusive => true).bind(amq.fanout(identity)).subscribe do |msg|
        job_warden.process(msg)
      end
    end
  end
end

