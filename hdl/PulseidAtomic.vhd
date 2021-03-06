library ieee;

use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.Evr320StreamPkg.all;

entity PulseidAtomic is
  generic (
    PULSEID_OFFSET_G : natural := 52;
    PULSEID_BIGEND_G : boolean := false;
    PULSEID_LENGTH_G : natural := 8;
    PULSEID_WDOG_P_G : natural := 0;
    PULSEID_SEQERR_G : boolean := true;
    TSUPPER_OFFSET_G : natural := 40;
    TSLOWER_OFFSET_G : natural := 44;
    USE_ASYNC_OUTP_G : boolean := true
  );
  port (
    evrClk     : in  std_logic;
    evrRst     : in  std_logic;
    evrStream  : in  EvrStreamType;
    trg        : in  std_logic := '1';

    oclk       : in  std_logic;
    orst       : in  std_logic;

    -- pulseid, timeSecs, timeNsecs update synchronously while freeze is '0'
    freeze     : in  std_logic;

    pulseid    : out std_logic_vector(8*PULSEID_LENGTH_G - 1 downto 0);
    timeSecs   : out std_logic_vector(31 downto 0);
    timeNSecs  : out std_logic_vector(31 downto 0);

    -- asserted for 1 cycle when output triple updates
    strobe     : out std_logic;

    wdgErrors  : out std_logic_vector(31 downto 0);
    synErrors  : out std_logic_vector(31 downto 0);
    seqErrors  : out std_logic_vector(31 downto 0);
    pulseidCnt : out std_logic_vector(31 downto 0);
    status     : out std_logic
  );
end entity PulseidAtomic;

architecture rtl of PulseidAtomic is

  constant TS_LENGTH_C : natural := 4;

  type TimeStampType is record
    pulseid   : std_logic_vector(8*PULSEID_LENGTH_G - 1 downto 0);
    timeSecs  : std_logic_vector(8*TS_LENGTH_C      - 1 downto 0);
    timeNSecs : std_logic_vector(8*TS_LENGTH_C      - 1 downto 0);
    strobe    : std_logic;
  end record TimeStampType;

  constant TIMESTAMP_INIT_C : TimeStampType := (
    pulseid   => (others => '0'),
    timeSecs  => (others => '0'),
    timeNSecs => (others => '0'),
    strobe    => '0'
  );

  type RegType is record
    timeInp   : TimeStampType;
    timeOut   : TimeStampType;
  end record RegType;

  constant REG_INIT_C : RegType := (
    timeInp   => TIMESTAMP_INIT_C,
    timeOut   => TIMESTAMP_INIT_C
  );

  type ERegType is record
    lockout   : boolean;
    trg       : std_logic;
  end record ERegType;

  constant EREG_INIT_C : ERegType := (
    lockout   => true,
    trg       => '0'
  );

  signal r             : RegType  := REG_INIT_C;
  signal rin           : RegType;

  signal er            : ERegType := EREG_INIT_C;
  signal erin          : ERegType := EREG_INIT_C;

  signal timeLoc       : TimeStampType;
  signal trgLoc        : std_logic;

  signal pulseidStrobe : std_logic;
  signal tsHiStrobe    : std_logic;
  signal tsLoStrobe    : std_logic;
  signal lastStrobe    : std_logic;
  signal pidStatus     : std_logic;
  signal tsHiStatus    : std_logic;
  signal tsLoStatus    : std_logic;

  function max(a,b:natural) return natural is
  begin
    if ( a > b ) then return a; else return b; end if;
  end function max;

  function min(a,b:natural) return natural is
  begin
    if ( a > b ) then return b; else return a; end if;
  end function min;

  constant MIN_ADDR_C : natural := min(PULSEID_OFFSET_G, min(TSUPPER_OFFSET_G, TSLOWER_OFFSET_G));
  constant MAX_ADDR_C : natural := max(PULSEID_OFFSET_G + PULSEID_LENGTH_G, max(TSUPPER_OFFSET_G, TSLOWER_OFFSET_G) + TS_LENGTH_C) - 1;

begin

  -- assume stream arrives in ascending address order (and time-stamps/pulse-id are
  -- in the same segment!

  B_LastStrobe : block is
    -- reduce typing
    constant L_C : natural := TSLOWER_OFFSET_G;
    constant U_C : natural := TSUPPER_OFFSET_G;
    constant P_C : natural := PULSEID_OFFSET_G;
  begin
    lastStrobe <= pulseidStrobe when ((P_C >= U_C) and (P_C >= L_C)) else
                  tsHiStrobe    when ((U_C >= L_C) and (U_C >= P_C)) else
                  tsLoStrobe;
  end block B_LastStrobe;

  U_X_PulseId : entity work.PulseIdExtractor
    generic map (
      PULSEID_OFFSET_G => PULSEID_OFFSET_G,
      PULSEID_BIGEND_G => PULSEID_BIGEND_G,
      PULSEID_LENGTH_G => PULSEID_LENGTH_G,
      USE_ASYNC_OUTP_G => USE_ASYNC_OUTP_G,
      PULSEID_WDOG_P_G => PULSEID_WDOG_P_G,
      PULSEID_SEQERR_G => PULSEID_SEQERR_G
    )
    port map (
      clk              => evrClk,
      rst              => evrRst,
      evrStream        => evrStream,
      trg              => trgLoc,

      oclk             => oclk,
      orst             => orst,
      pulseid          => timeLoc.pulseid,
      pulseidStrobe    => pulseidStrobe,

      wdgErrors        => wdgErrors,
      synErrors        => synErrors,
      seqErrors        => seqErrors,
      pulseidCnt       => pulseidCnt,
      status           => pidStatus
    );

  U_X_TimeSecs : entity work.PulseIdExtractor
    generic map (
      PULSEID_OFFSET_G => TSUPPER_OFFSET_G,
      PULSEID_BIGEND_G => PULSEID_BIGEND_G,
      PULSEID_LENGTH_G => TS_LENGTH_C,
      USE_ASYNC_OUTP_G => USE_ASYNC_OUTP_G,
      PULSEID_WDOG_P_G => 0,
      PULSEID_SEQERR_G => false
    )
    port map (
      clk              => evrClk,
      rst              => evrRst,
      evrStream        => evrStream,
      trg              => trgLoc,

      oclk             => oclk,
      orst             => orst,
      pulseid          => timeLoc.timeSecs,
      pulseidStrobe    => tsHiStrobe,

      wdgErrors        => open,
      synErrors        => open,
      seqErrors        => open,
      pulseidCnt       => open,
      status           => tsHiStatus
    );

  U_X_TimeNSecs : entity work.PulseIdExtractor
    generic map (
      PULSEID_OFFSET_G => TSLOWER_OFFSET_G,
      PULSEID_BIGEND_G => PULSEID_BIGEND_G,
      PULSEID_LENGTH_G => TS_LENGTH_C,
      USE_ASYNC_OUTP_G => USE_ASYNC_OUTP_G,
      PULSEID_WDOG_P_G => 0,
      PULSEID_SEQERR_G => false
    )
    port map (
      clk              => evrClk,
      rst              => evrRst,
      evrStream        => evrStream,
      trg              => trgLoc,

      oclk             => oclk,
      orst             => orst,
      pulseid          => timeLoc.timeNSecs,
      pulseidStrobe    => tsLoStrobe,

      wdgErrors        => open,
      synErrors        => open,
      seqErrors        => open,
      pulseidCnt       => open,
      status           => tsLoStatus
    );


  P_COMB : process ( r, timeLoc, lastStrobe, freeze ) is
    variable v : RegType;
  begin
    v := r;

    if ( lastStrobe = '1' ) then
      v.timeInp := timeLoc;
      if ( freeze = '0' ) then
        v.timeOut := timeLoc;
        v.timeOut.strobe := '1';
        v.timeInp.strobe := '0';
      else
        -- frozen; just latch into the input reg and remember to strobe the output 
        v.timeInp.strobe := '1';
        v.timeOut.strobe := '0';
      end if;
    else
      if ( freeze = '0' ) then
        v.timeOut        := r.timeInp;
        v.timeInp.strobe := '0';
      end if;
    end if;

    rin <= v;
  end process P_COMB;

  P_ECOMB : process ( er, evrStream, trg ) is
    variable v : ERegType;
  begin
    v := er;

    if ( evrStream.valid = '1' ) then
      -- not locked out during the first address OK
      --  => trigger during first address cycle is acceptable
      v.lockout := (unsigned(evrStream.addr) >= MIN_ADDR_C) and (unsigned(evrStream.addr) < MAX_ADDR_C);
    end if;

    if ( er.lockout ) then
      if ( trg = '1' ) then
        v.trg := '1';
      end if;
    else
      v.trg := trg;
    end if;

    erin <= v;
  end process P_ECOMB;

  trgLoc <= '0' when er.lockout else er.trg;

  P_SEQ : process ( oclk ) is
  begin
    if ( rising_edge( oclk ) ) then
      if ( orst = '1' ) then
        r <= REG_INIT_C;
      else
        r <= rin;
      end if;
    end if;
  end process P_SEQ;

  P_ESEQ : process ( evrClk ) is
  begin
    if ( rising_edge( evrClk ) ) then
      if ( evrRst = '1' ) then
        er <= EREG_INIT_C;
      else
        er <= erin;
      end if;
    end if;
  end process P_ESEQ;


  pulseid   <= r.timeOut.pulseid;
  timeSecs  <= r.timeOut.timeSecs;
  timeNSecs <= r.timeOut.timeNSecs;
  strobe    <= r.timeOut.strobe;
  status    <= (pidStatus and tsHiStatus and tsLoStatus);

end architecture rtl;
