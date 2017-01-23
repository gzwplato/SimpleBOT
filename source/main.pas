unit main;

{$mode objfpc}{$H+}

interface

//TODO: Recorder
uses
  carik_controller,
  simplebot_controller, logutil_lib, fpjson,
  Classes, SysUtils, fpcgi, HTTPDefs, fastplaz_handler, database_lib;

const
  BOTNAME_DEFAULT = 'bot';

type

  { TMainModule }

  TMainModule = class(TMyCustomWebModule)
  private
    procedure BeforeRequestHandler(Sender: TObject; ARequest: TRequest);
    function defineHandler(const IntentName: string; Params: TStrings): string;

    function isTelegram: boolean;
    function isTelegramGroup: boolean;
    function isMentioned(Text: string): boolean;
  public
    Carik : TCarikController;
    SimpleBOT: TSimpleBotModule;
    constructor CreateNew(AOwner: TComponent; CreateMode: integer); override;
    destructor Destroy; override;

    procedure Get; override;
    procedure Post; override;
    function OnErrorHandler(const Message: string): string;
  end;

implementation

uses json_lib, common;

constructor TMainModule.CreateNew(AOwner: TComponent; CreateMode: integer);
begin
  inherited CreateNew(AOwner, CreateMode);
  BeforeRequest := @BeforeRequestHandler;

  Carik := TCarikController.Create;
end;

destructor TMainModule.Destroy;
begin
  Carik.Free;
  inherited Destroy;
end;

// Init First
procedure TMainModule.BeforeRequestHandler(Sender: TObject; ARequest: TRequest);
begin
end;

// GET Method Handler
procedure TMainModule.Get;
begin
  Response.Content := '{}';
end;

// POST Method Handler
// CURL example:
//   curl "http://local-bot.fastplaz.com/ai/" -X POST -d '{"message":{"message_id":0,"chat":{"id":0},"text":"Hi"}}'
procedure TMainModule.Post;
var
  json: TJSONUtil;
  text_response: string;
  Text, chatID, chatType, messageID, fullName, userName, telegramToken: string;
  i : integer;
  updateID, lastUpdateID: LongInt;
begin
  updateID := 0;

  // telegram style
  //   {"message":{"message_id":0,"text":"Hi","chat":{"id":0}}}
  json := TJSONUtil.Create;
  try
    json.LoadFromJsonString(Request.Content);
    Text := json['message/text'];
    if Text = 'False' then
      Text := '';
    updateID := s2i( json['update_id']);
    messageID := json['message/message_id'];
    chatID := json['message/chat/id'];
    chatType := json['message/chat/type'];
    //TODO: get full name from field 'message/from/first_name'
    userName := json['message/chat/username'];
    fullName := json['message/chat/first_name'] + ' ' + json['message/chat/last_name'];
  except
    // jika tidak ada di body, ambil dari parameter post
    Text := _POST['text'];
  end;

  // maybe submitted from post data
  if Text = '' then
    Text := _POST['text'];

  // CarikBOT isRecording
  Carik.GroupName := json['message/chat/title'];
  if isTelegram then
  begin
    if ((chatType = 'group') or (chatType = 'supergroup')) then
    begin
      if Carik.Recording then
      begin
        Carik.RecordTelegramMessage( Request.Content);
      end;
    end;
  end; // Carik - end

  if Text = '' then
    Exit;

  if isTelegram then
  begin
    //if isTelegramGroup then
    if ((chatType = 'group') or (chatType = 'supergroup')) then
      if not isMentioned(Text) then
      begin
        Response.Content := 'nop';
        Exit;
      end;

    //TODO: check is reply from groupchat

    // last message only
    lastUpdateID := s2i( _SESSION['UPDATE_ID']);
    if updateID < lastUpdateID then
    begin
      Exit;
    end;
    _SESSION['UPDATE_ID'] := updateID;
  end;// isTelegram

  SimpleBOT := TSimpleBotModule.Create;
  SimpleBOT.chatID := chatID;
  if userName <> '' then
  begin
    SimpleBOT.UserData['Name'] := userName;
    SimpleBOT.UserData['FullName'] := fullName;
  end;
  SimpleBOT.OnError := @OnErrorHandler;  // Your Custom Message
  SimpleBOT.Handler['define'] := @defineHandler;
  SimpleBOT.Handler['carik_rekam'] := @Carik.CarikHandler;
  SimpleBOT.Handler['carik_stop'] := @Carik.CarikHandler;
  text_response := SimpleBOT.Exec(Text);
  SimpleBOT.Free;

  // Send To Telegram
  // add paramater 'telegram=1' to your telegram url
  if isTelegram then
  begin
    telegramToken := Config[_TELEGRAM_CONFIG_TOKEN];
    if SimpleBOT.SimpleAI.Action = '' then // no mention reply, if no 'action'
      messageID := '';
    if SimpleBOT.SimpleAI.Action = 'telegram_menu' then
      messageID := '';
    for i := 0 to SimpleBOT.SimpleAI.ResponseText.Count - 1 do
    begin
      if i > 0 then
        messageID := '';
      SimpleBOT.TelegramSend(telegramToken,
        chatID, messageID,
        SimpleBOT.SimpleAI.ResponseText[i]);
    end;

    LogUtil.Add(Request.Content, 'input');

    //Response.Content := 'OK';
    //Exit;
  end;

  //---
  Response.ContentType := 'application/json';
  Response.Content := text_response;
end;

function TMainModule.defineHandler(const IntentName: string; Params: TStrings): string;
var
  keyName, keyValue: string;
begin

  // global define
  keyName := Params.Values['Key'];
  if keyName <> '' then
  begin
    keyName := Params.Values['Key'];
    keyValue := Params.Values['Value'];
    Result := keyName + ' = ' + keyValue;
    Result := SimpleBOT.GetResponse('HalBaru');
    Result := StringReplace(Result, '%word%', UpperCase(keyName), [rfReplaceAll]);
  end;

  Result := SimpleBOT.StringReplacement(Result);

  // Example Set & Get temporer user data
  {
  SimpleBOT.UserData[ 'name'] := 'Luri Darmawan';
  varstring :=   SimpleBOT.UserData[ 'name'];
  }

  // Save to database
  //   keyName & keyValue

end;

function TMainModule.isTelegram: boolean;
begin
  Result := False;
  if _GET['telegram'] = '1' then
    Result := True;
end;

function TMainModule.isTelegramGroup: boolean;
var
  json: TJSONUtil;
  chatType: string;
begin
  Result := False;
  json := TJSONUtil.Create;
  try
    json.LoadFromJsonString(Request.Content);
    chatType := json['message/chat/type'];
    if chatType = 'group' then
      Result := True;
    if chatType = 'supergroup' then
      Result := True;
  except
  end;
  json.Free;
end;

function TMainModule.isMentioned(Text: string): boolean;
begin
  Result := False;
  if pos('@' + BOTNAME_DEFAULT, Text) > 0 then
    Result := True;
  if pos('Bot', Text) > 0 then    // force dectect as Bot  (____Bot)
    Result := True;
end;

function TMainModule.OnErrorHandler(const Message: string): string;
var
  s: string;
begin
  s := Trim(Message);
  s := StringReplace(SimpleBOT.GetResponse('InginTahu', ''), '%word%',
    s, [rfReplaceAll]);
  Result := s;


  // simpan message ke DB, untuk dipelajari oleh AI

end;


end.
