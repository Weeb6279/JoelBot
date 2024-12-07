require "bundler/inline"
require "json"
require 'eventmachine'
require 'absolute_time'
require "awesome_print"
require 'faye/websocket'
require 'irb'
require 'time'

gemfile do
  source "https://rubygems.org"
  gem "faraday"
  gem "mysql2"
end

require 'faraday'
require 'mysql2'
require_relative "credentials.rb"
require_relative "colorString.rb"

$online = false

$twitch_token = nil
$joinedChannels = []
$acceptedJoels = ["GoldenJoel" , "Joel2" , "Joeler" , "Joel" , "jol" , "JoelCheck" , "JoelbutmywindowsXPiscrashing" , "JOELLINES", "Joeling", "Joeling", "LetHimJoel", "JoelPride", "WhoLetHimJoel", "Joelest", "EvilJoel", "JUSSY", "JoelJams", "JoelTrain", "BarrelJoel", "JoelWide1", "JoelWide2", "Joeling2"]
$followedChannels = ["jakecreatesstuff", "venorrak", "lcolonq", "prodzpod", "cr4zyk1tty", "tyumici", "colinahscopy_"]
$lastJoelPerStream = []
$lastStreamJCP = []
$commandChannels = ["venorrak", "prodzpod", "cr4zyk1tty", "jakecreatesstuff", "tyumici", "lcolonq", "colinahscopy_"]
$twoMinWait = AbsoluteTime.now
$initiationDateTime = Time.new()
$me_twitch_id = nil
$twitch_session_id = nil
$JCP = 0
$bus = nil

$sql = Mysql2::Client.new(:host => "localhost", :username => "bot", :password => "joel", :reconnect => true, :database => "joelScan")

$TokenService = Faraday.new(url: 'http://localhost:5002') do |conn|
  conn.request :url_encoded
end

$SQLService = Faraday.new(url: 'http://localhost:5001') do |conn|
  conn.request :url_encoded
end

$twitch_api = Faraday.new(url: 'https://api.twitch.tv') do |conn|
  conn.request :url_encoded
end

$ntfy_server = Faraday.new(url: 'https://ntfy.venorrak.dev') do |conn|
  conn.request :url_encoded
end



#function to get the access token for API 
def getTwitchToken()
  begin
    response = $TokenService.get("/token/twitch") do |req|
      req.headers["Authorization"] = $twitch_safety_string
    end
    rep = JSON.parse(response.body)
    $twitch_token = rep["token"]
  rescue
    puts "Token Service is down"
  end
end

def subscribeToTwitchEventSub(session_id, type, streamer_twitch_id)
  data = {
      "type" => type[:type],
      "version" => type[:version],
      "condition" => {
          "broadcaster_user_id" => streamer_twitch_id,
          "to_broadcaster_user_id" => $me_twitch_id,
          "user_id" => $me_twitch_id,
          "moderator_user_id" => $me_twitch_id
      },
      "transport" => {
          "method" => "websocket",
          "session_id" => session_id
      }
  }.to_json
  response = $twitch_api.post("/helix/eventsub/subscriptions", data) do |req|
      req.headers["Authorization"] = "Bearer #{$twitch_token}"
      req.headers["Client-Id"] = @client_id
      req.headers["Content-Type"] = "application/json"
  end
  return JSON.parse(response.body)
end

def unsubscribeToTwitchEventSub(subsciptionId)
  response = $twitch_api.delete("/helix/eventsub/subscriptions?id=#{subsciptionId}") do |req|
      req.headers["Authorization"] = "Bearer #{$twitch_token}"
      req.headers["Client-Id"] = @client_id
  end
  p response.status
end

def send_twitch_message(channel, message)
  if channel.is_a? Integer
    channel_id = channel
  else
    channel_id = getTwitchUser(channel)["data"][0]["id"]
  end
  begin
    message = "[📺] #{message}"
    request_body = {
        "broadcaster_id": channel_id,
        "sender_id": $me_twitch_id,
        "message": message
    }.to_json
    response_code = 429
    until response_code != 429
      response = $twitch_api.post("/helix/chat/messages", request_body) do |req|
          req.headers["Authorization"] = "Bearer #{$twitch_token}"
          req.headers["Client-Id"] = @client_id
          req.headers["Content-Type"] = "application/json"
      end
      response_code = response.status
    end
  rescue
    p "error sending message"
  end
end

#function to get the live channels from the channels array
def getLiveChannels()
  liveChannels = []
  channelsString = ""
  #https://dev.twitch.tv/docs/api/reference/#get-streams
  $followedChannels.each do |channel|
      response = $twitch_api.get("/helix/streams?user_login=#{channel}") do |req|
          req.headers["Authorization"] = "Bearer #{$twitch_token}"
          req.headers["Client-Id"] = @client_id
      end
      begin
        if response.status == 401
          getTwitchToken()
          return response.body
        end

        rep = JSON.parse(response.body)

        if rep.nil? || rep["data"].nil?
          return response.body
        end
        rep["data"].each do |stream|
          if stream["type"] == "live"
            liveChannels << "#{stream["user_login"]}"
          end
        end
      rescue => exception
        puts exception
        getTwitchToken()
        #if the response is not json or doesn't contain the data key
        return response.body
      end
  end
  return liveChannels
end

def getLastStreamJCP(channelName)
  # JCP = JoelCount / StreamDuration(in minutes)
  channelId = getTwitchUser(channelName)["data"][0]["id"] rescue nil
  if channelId.nil?
    return nil
  end
  response = $twitch_api.get("/helix/videos?user_id=#{channelId}&first=1&type=archive") do |req|
    req.headers["Authorization"] = "Bearer #{$twitch_token}"
    req.headers["Client-Id"] = @client_id
  end
  begin
    if response.status == 401
      getTwitchToken()
      return nil
    end

    rep = JSON.parse(response.body)
  rescue
    getTwitchToken()
    return nil
  end
  if rep["data"].count == 0
    videoDuration = "0m0s"
  else
    videoInfo = rep["data"][0]
    videoDuration = videoInfo["duration"]
  end
  #duration ex: 3m21s
  videoDuration.delete_suffix!("s")
  minutes = videoDuration.split("m")[0].to_f
  seconds = videoDuration.split("m")[1].to_f
  totalMinutes = (minutes * 60 + seconds) / 60
  totalJoelCountLastStream = sendQuery("GetTotalJoelCountLastStream", [channelName])["count"].to_i rescue 0
  return totalJoelCountLastStream / totalMinutes rescue 0
end

def updateLastStreamJCP()
  lastStreamJCP = []
  $followedChannels.each do |channel|
    lastStreamJCP = getLastStreamJCP(channel)
    if lastStreamJCP.nil?
      next
    end
    $lastStreamJCP << {channel: channel, JCP: lastStreamJCP}
  end
end

def updateJCP()
  now = Time.new()
  uptime = (now - $initiationDateTime) / 60
  joinedChannelsName = $joinedChannels.map { |channel| channel[:channel] }

  # get all the times since the last joel for each channel (online and offline)
  # get all the average joel per minute for each channel (online and offline)
  allTimesSinceLastJoel = []
  allAverageJoelPerMinute = []
  $followedChannels.each do |channel|
    if joinedChannelsName.include?(channel)
      timeSinceLastJoel = (now - $lastJoelPerStream.find { |channelData| channelData[:channel] == channel }[:lastJoel]) / 60#minutes
      p timeSinceLastJoel
      totalJoelCountLastStream = sendQuery("GetTotalJoelCountLastStream", [channel])["count"].to_f rescue 0.0
      p totalJoelCountLastStream
      joelPerMinute = totalJoelCountLastStream / ((Time.now() - $joinedChannels.find {|joinedChannel| joinedChannel[:channel] == channel}[:subscription_time]) / 60.0) rescue 0.0 # Joels per minute
      p joelPerMinute
    else
      joelPerMinute = $lastStreamJCP.find { |channelData| channelData[:channel] == channel }[:JCP] # Joels per minute
      minutePerJoel = 1.0 / joelPerMinute rescue 0 # Minutes per Joel
      if minutePerJoel != 0 && minutePerJoel != Float::INFINITY
        timeSinceLastJoel = uptime % minutePerJoel
      else
        timeSinceLastJoel = 0
      end
      
    end
    # p channel + " : " + timeSinceLastJoel.to_s + " / " + joelPerMinute.to_s

    if timeSinceLastJoel != 0
      allTimesSinceLastJoel << timeSinceLastJoel
    end
    if joelPerMinute > 0 && joelPerMinute != Float::INFINITY
      allAverageJoelPerMinute << joelPerMinute
    end
  end
  
  
  # average between $JCP calculated with timeSinceLastJoel and $JCP calculated with joel per minute (last stream & current stream)
  # if all the the timeSinceLastJoel are equal -> JCP = 100%
  # if the timeSinceLastJoel are different -> JCP = 100 * (1 - (max - min) / max)
  if !allTimesSinceLastJoel.empty? && !allAverageJoelPerMinute.empty?
    lastTimeJCP = 100 * (1 - (allTimesSinceLastJoel.max - allTimesSinceLastJoel.min) / allTimesSinceLastJoel.max)
    averageJCP = 100 * (1 - (allAverageJoelPerMinute.max - allAverageJoelPerMinute.min) / allAverageJoelPerMinute.max)

    $JCP = (lastTimeJCP + averageJCP) / 2
  end

  # printJCPStatus()
end

def printJCPStatus()
  puts ""
  puts "JCP : #{$JCP.round(2)}%".blue
  barString = "["
  $JCP.to_i.times do
    barString += "="
  end
  (100 - $JCP).to_i.times do
    barString += " "
  end
  barString += "]"
  puts barString
  puts ""
end

def updateJCPDB()
  if sendQuery("GetJCPlongAll", []).count == 0
    sendQuery("NewJCPLong", [$JCP, Time.now.strftime('%Y-%m-%d %H:%M:%S')])
  end
  if sendQuery("GetJCPshortAll", []).count == 0
    sendQuery("NewJCPShort", [$JCP, Time.now.strftime('%Y-%m-%d %H:%M:%S')])
  end

  lastLongJCP = sendQuery("GetLastLongJCP", [])
  lastShortJCP = sendQuery("GetLastShortJCP", [])

  if Time.now - Time.parse(lastLongJCP["timestamp"]) > 60
    sendQuery("NewJCPlong", [$JCP, Time.now.strftime('%Y-%m-%d %H:%M:%S')])
  end
  if Time.now - Time.parse(lastShortJCP["timestamp"]) > 15
    sendQuery("NewJCPshort", [$JCP, Time.now.strftime('%Y-%m-%d %H:%M:%S')])
  end

  # delete old data in JCPshort where the timestamp is older than 24 hours
  sendQuery("DeleteOldShortJCP", [(Time.now - 86400).strftime('%Y-%m-%d %H:%M:%S')])
end

def createEmptyDataForLastJoel()
  $followedChannels.each do |channel|
    $lastJoelPerStream << {channel: channel, lastJoel: Time.new()}
  end
end

def updateTrackedChannels()
  begin
    liveChannels = getLiveChannels()
  rescue
    liveChannels = []
    sendNotif("Bot stopped checking channels", "Alert")
  end
  if liveChannels.count > 0 && $online == false
    $online = true
    startWebsocket("wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30")
  else
    joinedChannelsName = $joinedChannels.map { |channel| channel[:channel] }
    #if there is multiple subscriptions to the same channel, keep only the last one based on the subscription time
    $joinedChannels = $joinedChannels.group_by { |channel| channel[:channel] }.map { |k, v| v.max_by { |channel| channel[:subscription_time] } }    

    $followedChannels.each do |channel|
      #if the channel is live and the bot is not in the channel
      if liveChannels.include?(channel) && !joinedChannelsName.include?(channel)
        begin
          subscribeData = subscribeToTwitchEventSub($twitch_session_id, {:type => "channel.chat.message", :version => "1"}, getTwitchUser(channel)["data"][0]["id"])
          $joinedChannels << {:channel => channel, :subscription_id => subscribeData["data"][0]["id"], :subscription_time => Time.now}
          send_twitch_message(channel, "JoelBot has entered the chat")
          sendNotif("Bot joined #{channel}", "Alert Bot Joined Channel")
        rescue => exception
          puts exception
          p subscribeData
          p $joinedChannels
        end
      end
      #if the channel is not live and the bot is in the channel
      if !liveChannels.include?(channel) && joinedChannelsName.include?(channel)
        leavingChannel = $joinedChannels.find { |channelData| channelData[:channel] == channel }
        unsubscribeToTwitchEventSub(leavingChannel[:subscription_id])
        $joinedChannels.delete(leavingChannel)
        send_twitch_message(channel, "JoelBot has left the chat")
        sendNotif("Bot left #{channel}", "Alert Bot Left Channel")
      end
    end
  end
end

#function to get the user info from the API
def getTwitchUser(name)
  response = $twitch_api.get("/helix/users?login=#{name}") do |req|
      req.headers["Authorization"] = "Bearer #{$twitch_token}"
      req.headers["Client-Id"] = @client_id
  end
  begin
    if response.status == 401
      getTwitchToken()
      return nil
    end

    rep = JSON.parse(response.body)
  rescue
    rep = nil
    getTwitchToken()
  end
  return rep
end

#function to send a notification to the ntfy server on JoelBot subject
def sendNotif(message, title)
  rep = $ntfy_server.post("/JoelBot") do |req|
      req.headers["host"] = "ntfy.venorrak.dev"
      req.headers["Priority"] = "5"
      req.headers["Title"] = title
      req.body = message
  end
end

#create a user and joel in the database
def createUserDB(name, userData, startJoels)
  pfp = nil
  bgp = nil
  twitch_id = nil
  user_id = 0
  pfp_id = 0
  bgp_id = 0
  if userData.nil?
    return
  end
  userData["data"].each do |user|
      twitch_id = user["id"]
      pfp = user["profile_image_url"]
      bgp = user["offline_image_url"]
  end

  sendQuery("NewPfp", [pfp])
  sendQuery("NewBgp", [bgp])
  
  pfp_id = sendQuery("GetPicture", [pfp])["id"]
  bgp_id = sendQuery("GetPicture", [bgp])["id"]

  sendQuery("NewUser", [twitch_id, pfp_id, bgp_id, name, DateTime.now.strftime("%Y-%m-%d")])

  #get the id of the new user
  user_id = sendQuery("GetUser", [name])["id"]

  #add the user to the joels table and set the count to 1
  sendQuery("NewJoel", [user_id, startJoels])
end

#create a channel and channelJoels in the database
def createChannelDB(channelName)
  channel_id = 0
  #add the channel to the database
  sendQuery("NewChannel", [channelName, DateTime.now.strftime("%Y-%m-%d")])

  #get the id of the new channel
  channel_id = sendQuery("GetChannel", [channelName])["id"]

  #add the channel to the channelJoels table and set the count to 1
  sendQuery("NewChannelJoels", [channelName])
end

def joelReceived(receivedData, nbJoel)
  userName = receivedData["payload"]["event"]["chatter_user_login"]
  channelName = receivedData["payload"]["event"]["broadcaster_user_login"]

  #update $lastJoelPerStream
  $lastJoelPerStream.each do |channel|
    if channel[:channel] == channelName
      channel[:lastJoel] = Time.new()
    end
  end

  #check if the user is in the database
  if sendQuery("GetUserArray", [userName]).count > 0
    sendQuery("UpdateJoel", [nbJoel, userName])
  else
    createUserDB(userName, getTwitchUser(userName), nbJoel)
  end
  #check if the channel is in the database
  if sendQuery("GetChannelArray", [channelName]).count > 0
    sendQuery("UpdateChannelJoels", [nbJoel, channelName])
  else
    createChannelDB(channelName)
  end
  #check if the channel owner is in the database
  if sendQuery("GetUserArray", [channelName]).count == 0
    createUserDB(channelName, getTwitchUser(channelName), 0)
  end
  #check if the stream is in the database
  if sendQuery("GetStreamJoelsToday", [channelName, DateTime.now.strftime("%Y-%m-%d")]) != nil
    sendQuery("UpdateStreamJoels", [nbJoel, channelName, DateTime.now.strftime("%Y-%m-%d")])
  else
    sendQuery("NewStreamJoels", [channelName, DateTime.now.strftime("%Y-%m-%d")])
  end

  #check if the User Joel stream is in the database
  if sendQuery("GetStreamUserJoels", [channelName, userName, DateTime.now.strftime("%Y-%m-%d")]) != nil
    sendQuery("UpdateStreamUserJoels", [nbJoel, channelName, userName, DateTime.now.strftime("%Y-%m-%d")])
  else
    sendQuery("NewStreamUserJoels", [channelName, DateTime.now.strftime("%Y-%m-%d"), userName, nbJoel])
  end
end

def treatCommands(words, receivedData)
  chatterName = receivedData["payload"]["event"]["chatter_user_login"]
  channelId = receivedData["payload"]["event"]["broadcaster_user_id"]
  broadcastName = receivedData["payload"]["event"]["broadcaster_user_login"]
  if $commandChannels.include?(broadcastName)
    case words[0].downcase
    when "!joelcount"
      if words[1] != "" && words[1] != nil
        username = words[1]
        count = sendQuery("GetUserCount", [username.downcase])
        if !count.nil?
          count = count["count"].to_i
          send_twitch_message(channelId.to_i, "#{username} has Joel'd #{count} times")
        else
          send_twitch_message(channelId.to_i, "#{username} didn't Joel yet")
        end
      else
        count = sendQuery("GetUserCount", [chatterName.downcase])
        if !count.nil?
          count = count["count"].to_i
          send_twitch_message(channelId.to_i, "#{chatterName} has Joel'd #{count} times")
        else
          send_twitch_message(channelId.to_i, "#{chatterName} didn't Joel yet")
        end
      end
    when "!joelcountchannel"
      if words[1] != "" && words[1] != nil
        channelName = words[1]
        count = sendQuery("GetChannelJoels", [channelName.downcase])
        if !count.nil?
          count = count["count"].to_i
          send_twitch_message(channelId.to_i, "Joel count on #{channelName} is #{count}")
        else
          send_twitch_message(channelId.to_i, "no Joel on #{channelName} channel yet")
        end
      else
        count = sendQuery("GetChannelJoels", [broadcastName.downcase])
        if !count.nil?
          count = count["count"].to_i
          send_twitch_message(channelId.to_i, "Joel count on #{broadcastName} is #{count}")
        else
          send_twitch_message(channelId.to_i, "no Joel on this channel yet")
        end
      end
    when "!joelcountstream"
      count = sendQuery("GetStreamJoelsToday", [broadcastName.downcase, DateTime.now.strftime("%Y-%m-%d")])
      if !count.nil?
        count = count["count"].to_i
        send_twitch_message(channelId.to_i, "Joel count on this stream is #{count}")
      else
        send_twitch_message(channelId.to_i, "no Joel today yet")
      end
    when "!joeltop"
      users = sendQuery("GetTop5Joels", [])
      message = ""
      users.each_with_index do |user, index|
        message += "#{user["name"]} : #{user["count"].to_i} | "
      end
      send_twitch_message(channelId.to_i, message)
    when "!joeltopchannel"
      channels = sendQuery("GetTop5JoelsChannel", [])
      message = ""
      channels.each_with_index do |channel, index|
        message += "#{channel["name"]} : #{channel["count"].to_i} | "
      end
      send_twitch_message(channelId.to_i, message)
    when "!joelcommands"
      send_twitch_message(channelId.to_i, "!JoelCount [username] / !JoelCountChannel [channelname] / !JoelCountStream - get the number of Joels on the current stream / !JoelTop - get the top 5 Joelers / !JoelTopChannel - get the top 5 channels with the most Joels / !joelStats [username] - gets basic stats from the user / !jcp - get the current jcp / !joelStatus - get the status of JoelBot")
    when "!joelstats"
      if words[1] != "" && words[1] != nil
        username = words[1]
      else
        username = chatterName
      end
      if sendQuery("GetUserArray", [username.downcase]).count > 0
        basicStats = sendQuery("GetBasicStats", [username.downcase])
        mostJoelStreamStats = sendQuery("GetMostJoelStreamStats", [username.downcase])
        mostJoeledStreamerStats = sendQuery("GetMostJoeledStreamerStats", [username.downcase])

        message = "#{username} has Joel'd #{basicStats["totalJoels"].to_i} times since #{basicStats["firstJoelDate"]} / "
        message += "Most Joels in a stream : #{mostJoelStreamStats["mostJoelsInStream"]} on #{mostJoelStreamStats["mostJoelsInStreamDate"]} on #{mostJoelStreamStats["MostJoelsInStreamStreamer"]} / "
        message += "Most Joeled streamer : #{mostJoeledStreamerStats["count"]} on #{mostJoeledStreamerStats["mostJoeledStreamer"]}"
        send_twitch_message(channelId.to_i, message)
      else
        send_twitch_message(channelId.to_i, "#{username} didn't Joel yet")
      end
    when "!jcp"
      send_twitch_message(channelId.to_i, "JCP : #{$JCP.round(2)}%")
    when "!joelstatus"
      send_twitch_message(channelId.to_i, "JoelBot is online")
    end
  end
end

def sendQuery(queryName, body)
  begin
    response = $SQLService.post("/joel/#{queryName}") do |req|
      req.headers['Content-Type'] = 'application/json'
      req.body = body.to_json
    end
    if response.status != 200
      p response.status
      p response.body
    else
      return JSON.parse(response.body)
    end
  rescue
    return {}
  end
end

getTwitchToken()
if $twitch_token.nil?
  puts "error getting twitch token".red
  exit
end
$me_twitch_id = getTwitchUser("venorrak")["data"][0]["id"]
if $me_twitch_id.nil?
  puts "error getting my twitch id".red
  exit
end
updateLastStreamJCP()
createEmptyDataForLastJoel()

Thread.start do
  loop do
    begin
      sleep(1)
      now = AbsoluteTime.now
      updateJCP()
      updateJCPDB()
      if now - $twoMinWait > 120
        updateTrackedChannels()
        updateLastStreamJCP()
        $twoMinWait = now
      end
    rescue => exception
      puts exception
      sendNotif("Bot stopped checking channels", "Alert")
      break
    end
  end
end

def startWebsocket(url, isReconnect = false)
  EM.run do
    ws = Faye::WebSocket::Client.new(url)

    ws.on :open do |event|
      #p [:open]
    end

    ws.on :message do |event|
      begin
        receivedData = JSON.parse(event.data)
      rescue
        puts "non json data"
        return
      end

      if receivedData["metadata"]["message_type"] == "session_welcome"
        $twitch_session_id = receivedData["payload"]["session"]["id"]
        liveChannels = getLiveChannels() rescue []
        joinedChannelsName = $joinedChannels.map { |channel| channel[:channel] }
        $followedChannels.each do |channel|
          #if the channel is live and the bot is not in the channel

          if joinedChannelsName.include?(channel)
            leavingChannel = $joinedChannels.find { |channelData| channelData[:channel] == channel }
            unsubscribeToTwitchEventSub(leavingChannel[:subscription_id])
            $joinedChannels.delete(leavingChannel)
          end

          if liveChannels.include?(channel) && !joinedChannelsName.include?(channel)
            begin
              subscribeData = subscribeToTwitchEventSub($twitch_session_id, {:type => "channel.chat.message", :version => "1"}, getTwitchUser(channel)["data"][0]["id"])
              $joinedChannels << {:channel => channel, :subscription_id => subscribeData["data"][0]["id"], :subscription_time => Time.now}
              if isReconnect == false
                send_twitch_message(channel, "JoelBot has entered the chat, !JoelCommands for commands")
                sendNotif("Bot joined #{channel}", "Alert Bot Joined Channel")
              end
            rescue => exception
              puts exception
              p subscribeData
              p $joinedChannels
            end
          end
        end
      end

      if receivedData["metadata"]["message_type"] == "session_reconnect"
        startWebsocket(receivedData["payload"]["session"]["reconnect_url"], true)
      end

      if receivedData["metadata"]["message_type"] == "notification"
        case receivedData["payload"]["subscription"]["type"]
        when "channel.chat.message"
          message = receivedData["payload"]["event"]["message"]["text"]
          puts "#{receivedData["payload"]["event"]["chatter_user_login"]}: #{message}"
          words = message.strip.split(" ")
          treatCommands(words, receivedData)
          nbJoelInMessage = 0
          words.each do |word|
            if $acceptedJoels.include?(word)
              nbJoelInMessage += 1
            end
          end
          if nbJoelInMessage > 0
            #if the message is not sent by the bot
            if receivedData["payload"]["event"]["chatter_user_login"] == "venorrak" && words[0] == "[📺]"
              print("")
            else
              joelReceived(receivedData, nbJoelInMessage)
            end
          end
        end
      end
    end

    ws.on :close do |event|
      p [Time.now().to_s.split(" ")[1], :close, event.code, event.reason, "twitch"]
      if event.code != 1000
        #sendNotif("JoelBot Disconnected : #{event.code} : #{event.reason}", "JoelBot")
        if getLiveChannels().count > 0
          startWebsocket("wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30", true)
          $online = true
        else
          $online = false
        end
      end
    end
  end
end

if getLiveChannels().count > 0
  $online = true
  startWebsocket("wss://eventsub.wss.twitch.tv/ws?keepalive_timeout_seconds=30")
end

Thread.start do
  EM.run do
    bus = Faye::WebSocket::Client.new('ws://192.168.0.16:5963')
  
    bus.on :open do |event|
      p [:open, "BUS"]
      $bus = bus
    end
  
    bus.on :message do |event|
      begin
        data = JSON.parse(event.data)
      rescue
        data = event.data
      end
  
      if data["to"] == "all" && data["from"] == "BUS"
        if data["payload"]["type"] == "token_refreshed"
          case data["payload"]["client"]
          when "twitch"
            getTwitchToken()
          end
        end
      end
    end
  
    bus.on :error do |event|
      p [:error, event.message, "BUS"]
    end
  
    bus.on :close do |event|
      p [:close, event.code, event.reason, "BUS"]
    end
  end
end

#keep the bot running until the user types exit
input = ""
until input == "exit"
  input = gets.chomp
  if input == "irb"
    binding.irb
  end
end



# - gcp
#   -has servers sending random numbers
#   -calculates how far apart the numbers are
#   -if they are far apart = high network variance
#   -if they are close = low network variance
#
# - Joelbot (Jcp)
#   -connects to twitch chat
#   -Each channel is a server sending Joels (equivalent to random numbers)
#   -calculates how far apart the Joels are
#   -if they are far apart = high Joel variance
#   -if they are close = low Joel variance
#   -PROBLEM : how to calculate the variance of the Joels if only one channel is live ?
#   -SOLUTION : Create Joels from last stream for each tracked channels (joelCount / streamDuration)
