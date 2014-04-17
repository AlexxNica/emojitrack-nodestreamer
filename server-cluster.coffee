cluster = require('cluster')

################################################################################
#                      _
#  _ __ ___   __ _ ___| |_ ___ _ __
# | '_ ` _ \ / _` / __| __/ _ \ '__|
# | | | | | | (_| \__ \ ||  __/ |
# |_| |_| |_|\__,_|___/\__\___|_|
#
################################################################################

if cluster.isMaster
  config         = require('./lib/config')
  ScorePacker    = require('./lib/scorePacker')

  debug    = require('debug')('emojitrack-sse:clusterMaster')
  cpuCount = require('os').cpus().length
  numWorkers  = if cpuCount >= 2 then (cpuCount - 1) else 1
  cluster.fork() for [1..numWorkers]

  workerBroadcast = (msg) ->
    cluster.workers[id].send(msg) for id in Object.keys(cluster.workers)

  ###
  # redis event stuff
  ###
  redisStreamClient = config.redis_connect()
  scorepacker = new ScorePacker(17) #17ms

  redisStreamClient.subscribe('stream.score_updates')
  redisStreamClient.psubscribe('stream.tweet_updates.*')
  # redis.psubscribe('stream.interaction.*')

  redisStreamClient.on 'message', (channel, msg) ->
    # in theory we could check the channel, but since we are only subscribed to one
    # let's not bother and save an unncessary comparison operation.  in future may be necessary.
    workerBroadcast {action: 'rawBroadcast', payload: {data: msg, event: null, channel: '/raw'}}
    scorepacker.increment(msg) #send to score packer for eps rollup stream

  redisStreamClient.on 'pmessage', (pattern, channel, msg) ->
    if pattern == 'stream.tweet_updates.*'
      channelID = channel.split('.')[2]
      workerBroadcast {
                        action: 'detailBroadcast'
                        payload: {
                          data: msg
                          event: "/details/#{channelID}"
                          channel: "/details/#{channelID}"
                        }
                      }
    # else if pattern == 'stream.interaction.*'
    #TODO: reimplement me when we need kiosk mode again

  scorepacker.on 'expunge', (scores) ->
    workerBroadcast {action: 'epsBroadcast', payload: {data: JSON.stringify(scores), event: null, channel: '/eps'}}


################################################################################
#                     _
# __      _____  _ __| | _____ _ __
# \ \ /\ / / _ \| '__| |/ / _ \ '__|
#  \ V  V / (_) | |  |   <  __/ |
#   \_/\_/ \___/|_|  |_|\_\___|_|
#
################################################################################

if cluster.isWorker
  debug   = require('debug')("emojitrack-sse:worker:#{cluster.worker.id}")
  app     = require('express')()
  http    = require('http')
  server  = http.Server(app)

  config         = require('./lib/config')
  ConnectionPool = require('./lib/connectionPool')
  Monitor = require('./lib/monitor')

  ###
  # stand up services
  ###
  # http.globalAgent.maxSockets = 1024
  if config.ENV is 'staging' or config.ENV is 'production'
    # trust x forwarded for headers from proxy (heroku routing)
    app.enable('trust proxy')
    # enable new relic reporting
    require('newrelic')

  server.listen config.PORT, ->
    console.log("Worker #{cluster.worker.id} listening on " + config.PORT)

  ###
  # routing event stuff
  ###
  rawClients     = new ConnectionPool()
  epsClients     = new ConnectionPool()
  detailClients  = new ConnectionPool()
  #kiosk_clients = new ConnectionPool()

  app.get '/subscribe/raw', (req, res) ->
    rawClients.provision req,res,'/raw'

  app.get '/subscribe/eps', (req, res) ->
    epsClients.provision req,res,'/eps'

  app.get '/subscribe/details/:id', (req, res) ->
    detailClients.provision req,res,"/details/#{req.params.id}"

  ###
  # worker receive event stuff
  ###
  process.on 'message', (msg) ->
    switch msg.action
      when 'rawBroadcast'    then rawClients.broadcast msg.payload
      when 'epsBroadcast'    then epsClients.broadcast msg.payload
      when 'detailBroadcast' then detailClients.broadcast msg.payload

# ###
# # monitoring
# ###
# monitor = new Monitor(rawClients,epsClients,detailClients)
# app.get '/subscribe/admin/node.json', (req, res) ->
#   res.json monitor.status_report()
