WebSocket = require ('ws')
createCanduit = require('canduit')
arrayCompare = require("array-compare")
Promise = require 'bluebird'

{Robot, Adapter, TextMessage, User} = require 'hubot'

class phaBot extends Adapter

  config: {
    api: null,
    token: null,
    ws_url: null,
    welcome_msg: "Welcome back!"
  }

  data: {}

  ws: null

  conduit: null

  roomList: []

  roomRefreshIntervalID: 0


  constructor: ->
    super
    @robot.logger.info "Constructor start"

    if process.env.PHA_API == undefined
      @robot.logger.error "PHA_API is undefined, please set environment variable. example: https://pha.domain.com/api/"
      process.exit()


    if process.env.PHA_TOKEN == undefined
      @robot.logger.error "PHA_TOKEN is undefined, please set environment variable"
      process.exit()


    if process.env.PHA_WS_URL == undefined
      @robot.logger.error "PHA_WS_URL is undefined, please set environment variable. example: wss://pha.domain.com:22280"
      process.exit()

    if process.env.PHA_WELCOME_MSG == undefined
      @robot.logger.info "PHA_WELCOME_MSG is undefined, will use default. #{@config.welcome_msg}"
    else
      @config.welcome_msg = process.env.PHA_WELCOME_MSG


    @config.api = process.env.PHA_API
    @config.token = process.env.PHA_TOKEN
    @config.ws_url = process.env.PHA_WS_URL

  ready: ->
    @robot.logger.info "ready"

  run: ->
    self = @
    @robot.logger.info "Run"
    @emit 'connected'
    self.conduit = createCanduit self.config, (error, conduit)->
      self.connectPhaWS()

  send: (envelope, strings...) ->
    @robot.logger.info "Send"
    @sendMessageToRoom(strings[0], envelope.room)


  reply: (envelope, strings...) ->
    @robot.logger.info "Reply"
    @send envelope, strings...

#通过WebSocket连接Phabricatorr
  connectPhaWS: ->
    self = @
    @robot.logger.info "connecting phabricator. url:#{@config.ws_url}"
    self.roomList = [] #clear room list
    self.ws = new WebSocket(self.config.ws_url, null, {rejectUnauthorized: false});
    self.ws.onopen = ->
      self.robot.logger.info "websocket open"

      #定时刷新聊天室
      CHAT_ROOM_REFRESH_TIME = 5000;
      self.roomRefreshIntervalID = setInterval ()->
        self.getAllRooms() #获取所有我的聊天室, 并关注
      , CHAT_ROOM_REFRESH_TIME
      self.sendHeartbeat() #发送心跳

    self.ws.onmessage = (evt)->
      self.robot.logger.info "receive websocket msg:#{evt.data}"
      wsMsgObj = JSON.parse(evt.data)

      switch wsMsgObj.type
        when "message" then self.handleWSReceiveMessage (wsMsgObj) #去api拉消息实体

    self.ws.onclose = (evt)->
      self.robot.logger.error "WebSocket Closed!!!!!!!#{evt}"
      clearInterval(self.roomRefreshIntervalID);
      self.robot.logger.error "clear interval id:#{self.roomRefreshIntervalID}"
      self.robot.logger.error "after 10 second , re-connect"
      setTimeout(
        ()-> self.connectPhaWS()
      , 10000)

    self.ws.onerror = (evt)->
      self.robot.logger.error "WebSocket Error!!!!!!!#{evt}"

#发送心跳消息
  sendHeartbeat: ->
    self = @
    heart_jump_time = 30000; #heart jump time 30 second default
    heart_jump_msg = '{"command":"ping","data":null}'
    setInterval ()->
      self.robot.logger.info "send heart jump"
      self.ws.send heart_jump_msg
    , heart_jump_time


#订阅多个聊天室，使用PHID数组
  subscribeRooms: (conpherencePHIDs)->
    for phid in conpherencePHIDs
      @subscribeRoom(phid)


#订阅一个聊天室，使用PHID
  subscribeRoom: (conpherencePHID)->
    if @ws == null
      @robot.logger.error "webscoket not connect"
    else
      command = '{"command":"subscribe","data":["' + conpherencePHID + '","' + @.config.user_phid + '"]}'
      @robot.logger.info "send subscribe chat rooms webscoket:#{command}"
      @ws.send(command)

#获取所有与我有关的聊天室
  getAllRooms: ()->
    self = @
    self.robot.logger.info "get all chat rooms list"
    roomPhids = []

    params = {
      "limit": 999999
    }

    self.getConduit('conpherence.querythread', params).then((result)->
      self.robot.logger.info "get all chat rooms list result:#{result}"
      roomPhids.push result[key]['conpherencePHID'] for key of result

      if self.roomList.length < 1
        self.robot.logger.info 'roomList lengt <1 ,first init chat rooms'
        self.roomList = roomPhids
        self.subscribeRooms roomPhids
      else
        if roomPhids.toString() == self.roomList.toString()
          self.robot.logger.info 'chat rooms no changed'
        else
          self.robot.logger.info 'chat rooms changed, re-subscribe'
          addedRooms = self.checkNewAddRooms(self.roomList, roomPhids)

          self.roomList = roomPhids
          self.subscribeRooms addedRooms
          self.sendWelcomeToNewRooms(addedRooms)
    )

  sendWelcomeToNewRooms: (newRooms)->
    self = @
    self.robot.logger.info 'send_welcome_to_new_room'
    newRooms.map((newRoomPhid)-> self.sendMessageToRoom(self.config.welcome_msg, newRoomPhid))


#检查新增的room
  checkNewAddRooms: (oldPhids, newPhids)->
    addedRooms = arrayCompare(oldPhids, newPhids).added.map((value)-> return value.b)
    @robot.logger.info "checkNewAddRooms, addedRooms:#{addedRooms}"
    addedRooms


#处理WebSocket,message类型的数据
#调用Pha api查询内容，转发给hubot
  handleWSReceiveMessage: (wsMsgObj)->
    self = @

    roomPHID = wsMsgObj.threadPHID
    messageID = wsMsgObj.messageID

    self.robot.logger.info "pull msg from phabricator"

    params = {
      "limit": 3, #一次性拉取3条，匹配ID，防止说话过快，导致拉到的不是所说的话
      "roomPHID": roomPHID
    }

    self.conduit.exec "conpherence.querytransaction", params, (error, result)->
      self.robot.logger.info result
      if result == null
        self.robot.logger.info "msg obj is null , pass"
        return

      transactionType = result[messageID]['transactionType']
      authorPHID = result[messageID]['authorPHID']
      roomPHID = result[messageID]['roomPHID']
      content = result[messageID]['transactionComment']

      if content == null
        self.robot.logger.info "msg content is null, pass"
        return

      if transactionType == "participants"
        self.robot.logger.info "msg is system msg, pass"
        return

      self.getBotPHID().then((phid)->
        if authorPHID == phid
          self.robot.logger.info "msg is hubot self msg, pass"
          return
        else
          self.getUserInfo(authorPHID).then((userObj)->
            author = {
              userPhid: authorPHID
              roomPHID: roomPHID
              realName: userObj[0].realName
            }

            message = new TextMessage author, content, messageID
            self.robot.logger.info "forward message to hubot. Message content :" + message
            self.receive(message)
          )
      )


#发送消息：
  sendMessageToRoom: (content, roomPHID)->
    self = @
    @robot.logger.info 'send msg to room'
    @getConduit('conpherence.updatethread', {"phid": roomPHID, "message": content}).then(
      (res)-> self.robot.logger.info "msg send success #{res}"
    , (err)-> self.robot.logger.error "msg send fail #{err}"
    )

  getUserInfo: (userPHID)->
    @robot.logger.info "get user info from phabricator"
    params = {limit: 1, phids: {0: userPHID}}
    @getConduit('user.query', params).then((res)-> res)


  getConduit: (api, params)->
    self = @
    new Promise (res, err)->
      self.conduit.exec api, params, (error, result)->
        if result
          res result
        else
          err error

  getBotPHID: =>
    self = @
    console.log("getBotPHID")
    return new Promise (res, err) =>
      if self.data.bot_phid?
        self.robot.logger.info "getBotPHID from cache"
        res self.data.bot_phid
      else
        self.robot.logger.info "getBotPHID from API"
        self.getConduit('user.whoami', {}).then(
          (body)->
            self.data.bot_phid = body.phid
            res body.phid
        , (error)->
          err error
        )

exports.use = (robot) ->
  new phaBot robot
