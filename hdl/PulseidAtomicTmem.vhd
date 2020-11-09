library ieee;

use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.LedStripTcsrWrapperPkg.all;

-- Read the streamed data output of an EVR320 module and
-- make (integer) Pulse-ID and TimeStamp available to
-- software as one atomic reading.
--  - updates to the pulse-ID and time-stamp registers,
--    respectively, happen during the same clock cycle.
--  - 'strobe' is asserted during the first cycle after
--    an update of pulse-ID/time-stamp.
--  - while the 'freeze' bit is set in the control-register
--    updates are inhibited. This allows software to 
--    retrieve an atomic reading with multiple register
--    read operations.
--  - updates are re-enabled when 'freeze' is cleared.
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
--                     [0]: freeze readout
--                     [1]: reset (while asserted)
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

  -- pulseid, timeSecs, timeNsecs update synchronously while freeze is '0'
  signal freeze        : std_logic;

  signal pulseid       : std_logic_vector(8*PULSEID_LENGTH_G - 1 downto 0);
  signal timeSecs      : std_logic_vector(31 downto 0);
  signal timeNSecs     : std_logic_vector(31 downto 0);

  -- asserted for 1 cycle when output triple updates
  signal strobe        : std_logic;

  signal wdgErrors     : std_logic_vector(31 downto 0);
  signal synErrors     : std_logic_vector(31 downto 0);
  signal seqErrors     : std_logic_vector(31 downto 0);
  signal pulseidCnt    : std_logic_vector(31 downto 0);

  signal loc_DATR      : std_logic_vector(63 downto 0)       := (others => '0');

  constant LD_NUM_R64  : natural := 3;

  signal addr          : unsigned(3 + LD_NUM_R64 - 1 downto 3);

begin

  addr <= unsigned( xuser_TMEM_IF_ADD(addr'range) );

  U_X_PulseId : entity work.PulseIdAtomic
    generic map (
      PULSEID_OFFSET_G => PULSEID_OFFSET_G,
      PULSEID_BIGEND_G => PULSEID_BIGEND_G,
      PULSEID_LENGTH_G => PULSEID_LENGTH_G,
      PULSEID_WDOG_P_G => PULSEID_WDOG_P_G,
      TSUPPER_OFFSET_G => TSUPPER_OFFSET_G,
      TSLOWER_OFFSET_G => TSLOWER_OFFSET_G,
      USE_ASYNC_OUTP_G => USE_ASYNC_OUTP_G
    )
    port map (
      evrClk           => evrClk,
      evrRst           => evrRst,
      evrStream        => evrStream,
      trg              => trg,

      oclk             => xuser_CLK,
      orst             => xuser_RST,

      freeze           => freeze,
      pulseid          => pulseid,
      timeSecs         => timeSecs,
      timeNSecs        => timeNSecs,

      strobe           => strobe,

      wdgErrors        => wdgErrors,
      synErrors        => synErrors,
      seqErrors        => seqErrors,
      pulseidCnt       => pulseidCnt
    );

  P_rwRegs : process ( xuser_CLK ) is
  begin
    if ( rising_edge( xuser_CLK ) ) then
      if ( xuser_RST = '1' ) then
        freeze   <= '0';
        loc_DATR <= (others => '0');
      else
        -- readout
        if    ( addr = 0 ) then
          loc_DATR <= pulseid;
        elsif ( addr = 1 ) then
          loc_DATR <= timeSecs & timeNSecs;
        elsif ( addr = 2 ) then
          loc_DATR <= x"0000_0000_0000_000" & "000" & freeze;
        elsif ( addr = 3 ) then
          loc_DATR <= seqErrors & pulseidCnt;
        elsif ( addr = 4 ) then
          loc_DATR <= wdgErrors & synErrors;
        else
          loc_DATR <= (others => '0');
        end if;

        if ( (xuser_TMEM_IF_ENA = '1') ) then
          if    ( addr = 2 ) then
            if ( xuser_TMEM_IF_WE(0) = '1' ) then
              freeze <= xuser_TMEM_IF_DATW(0);
            end if;
          end if;
        end if;
      end if;
    end if;
  end process P_rwRegs;

  xuser_TMEM_IF_DATR <= loc_DATR;
  xuser_TMEM_IF_BUSY <= '0';
  xuser_TMEM_IF_PIPE <= "00";

end architecture rtl;
