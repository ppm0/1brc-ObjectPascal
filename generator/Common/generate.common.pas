unit Generate.Common;

{$IFDEF FPC}
{$mode ObjFPC}{$H+}
{$ENDIF}

interface

uses
  Classes
, SysUtils
{$IFDEF FPC}
{$ELSE}
{$ENDIF}
;

const
  cSeed: LongInt = 46668267; // '1BRC' in ASCII
  cColdestTemp = -99.9;
  cHottestTemp = 99.9;

type
{ TGenerator }
  TGenerator = class(TObject)
  private
    FInputFile: String;
    FOutPutFile: String;
    FLineCount: Int64;
    FStationNames: TStringList;

    procedure BuildStationNames;
    function GenerateProgressBar(
      APBPosition, APBMax, APBWIdth, AFileSize:Int64;
      ATimeElapsed: TDateTime
    ):String;
  protected
  public
    constructor Create(AInputFile, AOutputFile: String; ALineCount: Int64);
    destructor Destroy; override;

    procedure Generate;
  published
  end;

implementation

uses
  Math
{$IFDEF FPC}
, streamex
, bufstream
{$ELSE}
, System.Diagnostics
{$ENDIF}
;

const
  linesPercent = 10;
  stationsCapacity = 50000;
  chunkBatch = 10000;
  chunkCapacity = 20 * 1024 * 1024;
  lineEnding = #13#10;

{ TGenerator }

constructor TGenerator.Create(
  AInputFile,
  AOutputFile: String;
  ALineCount: Int64
);
begin
  FInputFile:= AInputFile;
  FOutPutFile:= AOutputFile;
  FLineCount:= ALineCount;

  FStationNames:= TStringList.Create;
  FStationNames.Capacity:= stationsCapacity;
  FStationNames.UseLocale:= False;
  FStationNames.Duplicates:= dupIgnore;
  FStationNames.Sorted:= True;
end;

destructor TGenerator.Destroy;
begin
  FStationNames.Free;
  inherited Destroy;
end;

procedure TGenerator.BuildStationNames;
var
  inputStream: TFileStream;
  streamReader: TStreamReader;
  entry: String;
  count: Int64 = 0;
  start, stop: Int64;
begin
  WriteLn('Building Weather Stations...');
  // Load the Weather Station names
  if FileExists(FInputFile) then
  begin
    inputStream:= TFileStream.Create(FInputFile, fmOpenRead);
    try
      streamReader:= TStreamReader.Create(inputStream);
      try
        {$IFDEF FPC}
        start:= GetTickCount64;
        while not streamReader.Eof do
        {$ELSE}
        start := TStopwatch.GetTimeStamp;
        while not streamReader.EndOfStream do
        {$ENDIF}
        begin
          entry:= streamReader.ReadLine;
          if entry[1] <> '#' then
          begin
            entry:= entry.Split(';')[0];
            FStationNames.Add(entry);
            Inc(count);
          end;
        end;
        {$IFDEF FPC}
        stop:= GetTickCount64;
        {$ELSE}
        stop := TStopwatch.GetTimeStamp;
        {$ENDIF}
      finally
        streamReader.Free;
      end;
    finally
      inputStream.Free;
    end;
  end
  else
  begin
    raise Exception.Create(Format('File "%s" not found.', [ FInputFile ]));
  end;
  WriteLn(Format('Done: Processed %.n entries from a total of %.n weather stations in %d ms', [
    Double(count),
    Double(FStationNames.Count),
    stop-start
  ]));
  WriteLn;
end;

function TGenerator.GenerateProgressBar(
  APBPosition, APBMax, APBWIdth, AFileSize: Int64;
  ATimeElapsed: TDateTime
): String;
var
  percentDone: Double;
  filled: Integer;
begin
  percentDone:= (100 * APBPosition) / APBMax;
  filled:= (APBWIdth * APBPosition ) div APBMax;
  Result:= '[';
  Result:= Result + StringOfChar('#', filled);
  Result:= Result + StringOfChar('-', APBWIdth - filled);
  Result:= Result + Format('] %5.2f %%', [ percentDone ]);
  Result:= Result + Format(' lines: %.n, file size: %.n, elapsed: %s    ', [
    Double(APBPosition),
    Double(AFileSize),
    FormatDateTime('n" min, "s" sec"', ATimeElapsed)
  ]);
end;

procedure TGenerator.Generate;
var
  index, progressBatch: Int64;
  stationId: Int64;
  randomTemp: Integer;
  randomTempStr: String[4];
  outputFileStream: TBufferedFileStream;
  chunkLine, randomTempFinal: String;
  stationArray, temperatureArray: TStringArray;
  LenStationArray, LenTemperatureArray: Array of Integer;
  chunkCount, chunkLen, stationsCount, temperaturesCount: Integer;
  start: TDateTime;
begin
  // Randomize sets this variable depending on the current time
  // We just set it to our own value
  RandSeed:= cSeed;

  // Build list of station names
  BuildStationNames;

  outputFileStream:= TBufferedFileStream.Create(FOutPutFile, fmCreate);

  progressBatch:= floor(FLineCount * (linesPercent / 100));
  start:= Now;

  // This is all paweld magic:
  // From here
  //based on code @domasz from lazarus forum, github: PascalVault
  stationsCount := FStationNames.Count;
  SetLength(stationArray, stationsCount);
  SetLength(LenStationArray, stationsCount);
  for index := 0 to stationsCount - 1 do
  begin
    stationArray[index] := FStationNames[index] + ';';
    LenStationArray[index] := Length(stationArray[index]);
  end;

  temperaturesCount := 1999;
  SetLength(temperatureArray, temperaturesCount);
  SetLength(LenTemperatureArray, temperaturesCount);
  temperatureArray[0] := '0.0' + lineEnding;
  LenTemperatureArray[0] := Length(temperatureArray[0]);
  for index := 1 to 999 do
  begin
    randomTempStr := IntToStr(index);
    case Ord(randomTempStr[0]) of
      1: randomTempFinal := '0.' + randomTempStr;
      2: randomTempFinal := randomTempStr[1] + '.' + randomTempStr[2];
      3: randomTempFinal := randomTempStr[1] + randomTempStr[2] + '.' + randomTempStr[3];
      4: randomTempFinal := randomTempStr[1] + randomTempStr[2] + randomTempStr[3] + '.' + randomTempStr[4];
    end;
    temperatureArray[index * 2 - 1] := randomTempFinal + lineEnding;
    LenTemperatureArray[index * 2 - 1] := Length(temperatureArray[index * 2 - 1]);
    temperatureArray[index * 2] := '-' + randomTempFinal + lineEnding;
    LenTemperatureArray[index * 2] := LenTemperatureArray[index * 2 - 1] + 1;
  end;

  chunkCount := chunkBatch;
  chunkLen := 0;
  SetLength(chunkLine, chunkCapacity);
  // To here

  try
    // Print first state of the progress bar
    Write(GenerateProgressBar(1, FLineCount, 50, 0, Now - start), #13);
    // Generate the file
    for index:= 1 to FLineCount do
    begin
      stationId:= Random(stationsCount);
      // This is all paweld magic:
      // From here
      randomTemp:= Random(temperaturesCount);
      Move(stationArray[stationId][1], chunkLine[chunkLen + 1], LenStationArray[stationId]);
      Inc(chunkLen, LenStationArray[stationId]);
      Move(temperatureArray[randomTemp][1], chunkLine[chunkLen + 1], LenTemperatureArray[randomTemp]);
      Inc(chunkLen, LenTemperatureArray[randomTemp]);

      Dec(chunkCount);
      if chunkCount = 0 then
      begin
        outputFileStream.WriteBuffer(chunkLine[1], chunkLen);
        chunkCount := chunkBatch;
        chunkLen := 0;
      end;
      // To here
      Dec(progressBatch);
      if progressBatch = 0 then
      begin
        Write(GenerateProgressBar(
          index,
          FLineCount,
          50,
          outputFileStream.Size,
          Now - start
        ), #13);
        progressBatch:= floor(FLineCount * (linesPercent / 100));
      end;
    end;
    if chunkCount > 0 then
    begin
      outputFileStream.WriteBuffer(chunkLine[1], chunkLen);
      outputFileStream.Flush;
    end;
  finally
    WriteLn;
    WriteLn;
    WriteLn(Format('Done: file size: %.n, elapsed: %s', [
      Double(outputFileStream.Size),
      FormatDateTime('n" min, "s" sec"', Now - start)
    ]));
    outputFileStream.Free;
  end;
end;

end.
