library ieee;

use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.Evr320StreamPkg.all;

-- Read the streamed data output of an EVR320 module and
-- make (integer) Pulse-ID and TimeStamp available to
-- software as one atomic reading.
--  - updates to the pulse-ID and time-stamp registers,
--    respectively, happen during the same clock cycle.
--  - 'strobe' is asserted during the first cycle after
--    an update of pulse-ID/time-stamp.
--  - while the 'freeze' count is negative (bit 7 set)
--    in the control-register updates are inhibited.
--    This allows software to retrieve an atomic reading
--    with multiple register read operations.
--    The value written to the 'freeze' field is subtracted
--    from the 'freeze' count. This allows for a simple
--    nested locking scheme in software:
--          write(freeze,  1);
--             // 1 subtracted from count
--             readout()
--          write(freeze, -1);
--             // 1 added back to count
--    if this algorithm is executed by multiple threads then
--    the freeze count falls below zero with the first
--    write(1) and reaches zero again when the last thread
--    leaves the critical section.
--  - updates are re-enabled when 'freeze[7]' is deasserted.
--  - reading the 'freeze' field yields the current count.
--  - registers are available for reading error counters
--
-- REGISTERS (64 bit)
--
--   Byte-Address    Description
--        0x00       pulse-id (integer, 64-bit)
--        0x08       time-stamp
--                     [63:32]: seconds,
--                     [31:00]: nano-seconds
--        0x10       control-register       
--                     [7:0]: freeze count
--                     [32] : reset counters (while asserted)
--                     [34] : override 'trg' (permanently assert)
--                   The readout is frozen while
--                   bit 7 is asserted. The value
--                   written to this field is *subtracted*
--                   from the current 'freeze' value.
--        0x18       counter-register 0
--                     [63:32]: sequence Errors
--                     [31:00]: pulse-id Counter
--        0x20       counter-register 1
--                     [63:32]: watchdog Timeouts
--                     [31:00]: synchronization Errors
--
-- Sequence Errors: incremented when consecutively
--                  received pulse-IDs do not differ
--                  by one.
-- Synchronization Errors: incremented when not all
--                  bytes of the pulse-ID were received
--                  from the EVR stream.
-- Watchdog Timeouts: incremented if no new pulse-id
--                  is read from the stream within the
--                  watchdog period.

entity PulseidAtomicTmem is
  generic (
    -- offset of 1st byte of pulse-ID in EVR320 stream
    PULSEID_OFFSET_G : natural := 52;
    -- endian-ness of pulse-id and time-stamp in the stream
    PULSEID_BIGEND_G : boolean := false;
    -- length of (integer) pulse-ID
    PULSEID_LENGTH_G : natural := 8;
    -- pulse-id watchdog timer period (in xuser_CLK cycles).
    -- If pulse ID is not updated within the watchdog
    -- period then the respective error counter is
    -- incremented. A period of zero disables the watchdog.
    PULSEID_WDOG_P_G : natural := 0;
    -- check whether pulse-ids are sequential; maintain
    -- a respective statistics counter
    PULSEID_SEQERR_G : boolean := true;
    -- offset of 1st byte of time-stamp seconds in stream
    TSUPPER_OFFSET_G : natural := 40;
    -- offset of 1st byte of time-stamp nano-seconds in
    -- stream
    TSLOWER_OFFSET_G : natural := 44;
    -- whether to instantiate synchronizers (set to false
    -- if evrClk and xuser_CLK are identical).
    USE_ASYNC_OUTP_G : boolean := true;
    -- left-most bit of TMEM address
    ADD_LEFT_BIT_P_G : natural := 23
  );
  port (
    -- clock/reset of EVR stream
    evrClk             : in  std_logic;
    evrRst             : in  std_logic;
    evrStream          : in  EvrStreamType;
    -- 'trg' can be used to decimate and/or delay pulse-ID readout.
    -- The pulse-id (and time-stamp) is double-buffered internally.
    -- The first ('capture') register registers data as soon as it is
    -- read from the stream. The second buffer ('readout register')
    -- is only updated from the capture register if 'trg' is asserted.
    trg                : in  std_logic := '1';

    -- TMEM clock/reset
    xuser_CLK          : in  std_logic;
    xuser_RST          : in  std_logic;

    -- asserted for 1 cycle when output triple updates
    strobe             : out std_logic;
    pulseid            : out std_logic_vector(8*PULSEID_LENGTH_G - 1 downto 0);

    -- TMEM interface
    xuser_TMEM_IF_ENA  : in  std_logic;
    xuser_TMEM_IF_ADD  : in  std_logic_vector(ADD_LEFT_BIT_P_G downto 3);
    xuser_TMEM_IF_DATW : in  std_logic_vector(63 downto 0);
    xuser_TMEM_IF_WE   : in  std_logic_vector( 7 downto 0);
    xuser_TMEM_IF_DATR : out std_logic_vector(63 downto 0);
    xuser_TMEM_IF_BUSY : out std_logic;
    xuser_TMEM_IF_PIPE : out std_logic_vector( 1 downto 0)
  );
end entity PulseidAtomicTmem;

architecture rtl of PulseidAtomicTmem is

  constant TRIG_FORCE_DEFAULT_C : std_logic := '0';

  -- pulseid, timeSecs, timeNsecs update synchronously while freeze is '0'
  signal freeze        : unsigned(7 downto 0) := (others => '0');
  signal rstCounters   : std_logic := '0';
  signal loc_xuser_RST : std_logic;

  signal pulseidLoc    : std_logic_vector(8*PULSEID_LENGTH_G - 1 downto 0);
  signal timeSecs      : std_logic_vector(31 downto 0);
  signal timeNSecs     : std_logic_vector(31 downto 0);

  signal wdgErrors     : std_logic_vector(31 downto 0);
  signal synErrors     : std_logic_vector(31 downto 0);
  signal seqErrors     : std_logic_vector(31 downto 0);
  signal pulseidCnt    : std_logic_vector(31 downto 0);
  signal status        : std_logic;

  signal loc_DATR      : std_logic_vector(63 downto 0)       := (others => '0');

  constant LD_NUM_R64  : natural := 3;

  signal addr          : unsigned(3 + LD_NUM_R64 - 1 downto 3);

  signal trgForceXuser : std_logic := TRIG_FORCE_DEFAULT_C;
  signal trgForceEvr   : std_logic;

  signal trgForced     : std_logic;

begin

  addr          <= unsigned( xuser_TMEM_IF_ADD(addr'range) );
  loc_xuser_RST <= (xuser_RST or rstCounters);

  G_AsyncTrigForce : if ( USE_ASYNC_OUTP_G ) generate
    attribute ASYNC_REG     : string;
    attribute KEEP          : string;
    constant  SYNC_STAGES_C : positive := 2;

    signal syncTrgForce : std_logic_vector(SYNC_STAGES_C - 1 downto 0) := (others => TRIG_FORCE_DEFAULT_C);

    attribute ASYNC_REG of syncTrgForce : signal is "TRUE";
    attribute KEEP      of syncTrgForce : signal is "TRUE";
  begin

    P_SyncTrigForce : process ( evrClk ) is
    begin
      if ( rising_edge( evrClk ) ) then
        if ( evrRst = '1' ) then
          syncTrgForce <= (others => TRIG_FORCE_DEFAULT_C);
        else
          syncTrgForce <= (syncTrgForce(syncTrgForce'left - 1 downto 0) & trgForceXuser);
        end if;
      end if;
    end process P_SyncTrigForce;

    trgForceEvr <= syncTrgForce(syncTrgForce'left);

  end generate G_AsyncTrigForce;

  G_SyncTrigForce : if ( not USE_ASYNC_OUTP_G ) generate
    trgForceEvr <= trgForceXuser;
  end generate G_SyncTrigForce;

  trgForced <= (trg or trgForceEvr);

  U_X_PulseId : entity work.PulseIdAtomic
    generic map (
      PULSEID_OFFSET_G => PULSEID_OFFSET_G,
      PULSEID_BIGEND_G => PULSEID_BIGEND_G,
      PULSEID_LENGTH_G => PULSEID_LENGTH_G,
      PULSEID_WDOG_P_G => PULSEID_WDOG_P_G,
      PULSEID_SEQERR_G => PULSEID_SEQERR_G,
      TSUPPER_OFFSET_G => TSUPPER_OFFSET_G,
      TSLOWER_OFFSET_G => TSLOWER_OFFSET_G,
      USE_ASYNC_OUTP_G => USE_ASYNC_OUTP_G
    )
    port map (
      evrClk           => evrClk,
      evrRst           => evrRst,
      evrStream        => evrStream,
      trg              => trgForced,

      oclk             => xuser_CLK,
      orst             => loc_xuser_RST,

      freeze           => freeze(freeze'left),
      pulseid          => pulseidLoc,
      timeSecs         => timeSecs,
      timeNSecs        => timeNSecs,

      strobe           => strobe,

      wdgErrors        => wdgErrors,
      synErrors        => synErrors,
      seqErrors        => seqErrors,
      pulseidCnt       => pulseidCnt,
      status           => status
    );

  P_rwRegs : process ( xuser_CLK ) is
  begin
    if ( rising_edge( xuser_CLK ) ) then
      if ( xuser_RST = '1' ) then
        freeze        <= (others => '0');
        rstCounters   <= '0';
        loc_DATR      <= (others => '0');
        trgForceXuser <= TRIG_FORCE_DEFAULT_C;
      else
        -- readout
        if    ( addr = 0 ) then
          loc_DATR <= pulseidLoc;
        elsif ( addr = 1 ) then
          loc_DATR <= timeSecs & timeNSecs;
        elsif ( addr = 2 ) then
          loc_DATR <=    x"0000_000" & "0" & trgForceXuser & status & rstCounters
                      &  x"0000_00"  & std_logic_vector(freeze);
        elsif ( addr = 3 ) then
          loc_DATR <= seqErrors & pulseidCnt;
        elsif ( addr = 4 ) then
          loc_DATR <= wdgErrors & synErrors;
        else
          loc_DATR <= (others => '0');
        end if;

        -- write
        if ( (xuser_TMEM_IF_ENA = '1') ) then
          if    ( addr = 2 ) then
            if ( xuser_TMEM_IF_WE(0) = '1' ) then
              freeze      <= freeze - unsigned(xuser_TMEM_IF_DATW(freeze'range));
            end if;
            if ( xuser_TMEM_IF_WE(4) = '1' ) then
              rstCounters   <= xuser_TMEM_IF_DATW(32);
              trgForceXuser <= xuser_TMEM_IF_DATW(34);
            end if;
          end if;
        end if;
      end if;
    end if;
  end process P_rwRegs;

  xuser_TMEM_IF_DATR <= loc_DATR;
  xuser_TMEM_IF_BUSY <= '0';
  xuser_TMEM_IF_PIPE <= "00";

  pulseid            <= pulseidLoc;

end architecture rtl;
