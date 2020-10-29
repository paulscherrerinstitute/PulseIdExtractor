library ieee;

use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.LedStripTcsrWrapperPkg.all;

-- assumes addresses are presented in ascending order
entity PulseidExtractor is
  generic (
    PULSEID_OFFSET_G  : natural := 0;    -- byte-offset in data memory
    PULSEID_BIGEND_G  : boolean := true; -- endian-ness
    PULSEID_LENGTH_G  : natural := 8;    -- in bytes
    USE_ASYNC_OUTP_G  : boolean := true;
    PULSEID_WDOG_P_G  : natural := 0     -- watchdog for missing pulse IDs; cycle count in 'clk' cycles (disabled when 0).
  );
  port (
    clk               : in  std_logic;
    rst               : in  std_logic;
    evrStream         : in  EvrStreamType;
    trg               : in  std_logic := '1'; -- register last pulseid to output
    oclk              : in  std_logic;
    orst              : in  std_logic;
    pulseid           : out std_logic_vector(8*PULSEID_LENGTH_G - 1 downto 0);
    pulseidStrobe     : out std_logic; -- asserted for 1 cycle when a new ID is registered on 'pulseid'
    wdgErrors         : out std_logic_vector(31 downto 0);
    synErrors         : out std_logic_vector(31 downto 0);
    pulseidCnt        : out std_logic_vector(31 downto 0)
  );
end entity PulseidExtractor;

architecture rtl of PulseidExtractor is

  type DemuxType is array (natural range 0 to PULSEID_LENGTH_G - 2) of std_logic_vector(7 downto 0);

  type RegClkType is record
    demux        : DemuxType;
    updated      : std_logic;
    pulseidReg   : std_logic_vector(8*PULSEID_LENGTH_G     - 1 downto 0);
    pulseid      : std_logic_vector(8*PULSEID_LENGTH_G     - 1 downto 0);
    strobe       : std_logic;
    got          : std_logic_vector(PULSEID_LENGTH_G - 1 downto 0);
    synErr       : std_logic;
    wdgStrobe    : std_logic;
    lastAddr     : std_logic_vector(evrStream.addr'range);
  end record RegClkType;

  constant REG_CLK_INIT_C : RegClkType := (
    demux        => (others => (others => '0')),
    updated      => '0',
    pulseidReg   => (others => '0'),
    pulseid      => (others => '0'),
    strobe       => '0',
    synErr       => '0',
    wdgStrobe    => '0',
    got          => (others => '0'),
    lastAddr     => (others => '1') -- pulse-id cannot overlap this address
  );

  type RegOClkType is record
    synErrors    : unsigned(31 downto 0);
    wdgStrobe    : natural range 0 to PULSEID_WDOG_P_G;
    wdgErrors    : unsigned(31 downto 0);
    pulseidCnt   : unsigned(31 downto 0);
  end record RegOClkType;

  constant REG_OCLK_INIT_C : RegOClkType := (
    synErrors    => (others => '0'),
    wdgStrobe    => PULSEID_WDOG_P_G,
    wdgErrors    => (others => '0'),
    pulseidCnt   => (others => '0')
  );

  function STAGES_F return natural is
  begin
    if ( USE_ASYNC_OUTP_G ) then return 2; else return 0; end if;
  end function STAGES_F;

  constant   STAGES_C  : natural := STAGES_F;

  attribute  KEEP      : string;
  attribute  ASYNC_REG : string;

  signal syncStrobe    : std_logic_vector(STAGES_C               downto 0) := (others => '0');
  signal syncSynErr    : std_logic_vector(STAGES_C               downto 0) := (others => '0');
  signal syncWdgStb    : std_logic_vector(STAGES_C               downto 0) := (others => '0');

  attribute ASYNC_REG of syncStrobe: signal is "TRUE";
  attribute KEEP      of syncStrobe: signal is "TRUE";
  attribute ASYNC_REG of syncSynErr: signal is "TRUE";
  attribute KEEP      of syncSynErr: signal is "TRUE";
  attribute ASYNC_REG of syncWdgStb: signal is "TRUE";
  attribute KEEP      of syncWdgStb: signal is "TRUE";

  signal rClk          : RegClkType  := REG_CLK_INIT_C;
  signal rinClk        : RegClkType;
  signal rOClk         : RegOClkType := REG_OCLK_INIT_C;
  signal rinOClk       : RegOClkType;

  signal synErr        : std_logic;
  signal wdgStb        : std_logic;
  signal strobe        : std_logic;

  function SYNC_OK_F return std_logic_vector is
    variable v : std_logic_vector(PULSEID_LENGTH_G - 1 downto 0);
  begin
    v         := (others => '1');
    v(v'left) := '0';
    return v;
  end function SYNC_OK_F;

begin

  P_SYNC_ERRS : process ( oclk ) is
  begin
    if ( rising_edge( oclk ) ) then
      if ( orst = '1' ) then
        syncSynErr <= (others => '0');
        syncWdgStb <= (others => '0');
        syncStrobe <= (others => '0');
      else
        syncSynErr <= syncSynErr( syncSynErr'left - 1 downto syncSynErr'right) & rClk.synErr;
        syncWdgStb <= syncWdgStb( syncWdgStb'left - 1 downto syncWdgStb'right) & rClk.wdgStrobe;
        syncStrobe <= syncStrobe( syncStrobe'left - 1 downto syncStrobe'right) & rClk.strobe;
      end if;
    end if;
  end process P_SYNC_ERRS;

  G_Async : if ( USE_ASYNC_OUTP_G ) generate

    synErr <= (syncSynErr(syncSynErr'left) xor syncSynErr(syncSynErr'left - 1));
    wdgStb <= (syncWdgStb(syncWdgStb'left) xor syncWdgStb(syncWdgStb'left - 1));
    strobe <= (syncStrobe(syncStrobe'left) xor syncStrobe(syncStrobe'left - 1));
  end generate G_Async;

  G_Sync : if ( not USE_ASYNC_OUTP_G ) generate
    synErr <= (syncSynErr(syncSynErr'left) xor rClk.synErr   );
    wdgStb <= (syncWdgStb(syncWdgStb'left) xor rClk.wdgStrobe);
    strobe <= (syncStrobe(syncStrobe'left) xor rClk.strobe   );
  end generate G_Sync;

  P_CLK_COMB : process( rClk, evrStream, trg ) is
    variable v        : RegClkType;
    variable offset   : signed(evrStream.addr'left + 1 downto evrStream.addr'right);
    constant END_OFF  : natural := PULSEID_LENGTH_G - 1;
    variable demuxVec : std_logic_vector( 8*v.demux'length - 1 downto 0 );
  begin

    v := rClk;

	if ( evrStream.valid = '1' ) then
      v.lastAddr := evrStream.addr;
      if ( evrStream.addr /= rClk.lastAddr ) then
        offset := signed(resize(unsigned(evrStream.addr),offset'length)) - PULSEID_OFFSET_G;
        if ( offset >= 0 ) then
          if ( offset < END_OFF ) then
            if ( v.got( to_integer(offset) ) = '1' ) then
              v.got := (others => '0');
            else
              v.got( to_integer(offset) ) := '1';
            end if;

            if ( PULSEID_BIGEND_G ) then
              v.demux(v.demux'right - to_integer(offset)) := evrStream.data;
            else
              v.demux(to_integer(offset))                 := evrStream.data;
            end if;
          elsif ( offset = END_OFF ) then

            v.got := (others => '0');

            if ( rClk.got /= SYNC_OK_F ) then
              v.synErr    := not rClk.synErr;
            else
              for i in v.demux'range loop
                demuxVec( 8*i + 7 downto 8* i) := rClk.demux(i);
              end loop;

              if ( PULSEID_BIGEND_G ) then
                v.pulseidReg := demuxVec & evrStream.data;
              else
                v.pulseidReg := evrStream.data & demuxVec;
              end if;

              v.updated   := '1';
              -- strobe the watchdog; a new pulse-ID was recorded
              v.wdgStrobe := not rClk.wdgStrobe;
            end if;

          end if; -- offset <= END_OFF
        end if; -- offset >= 0
      end if; -- evrStream.addr /= rClk.lastAddr
    end if; -- evrStream.valid = '1'

    if ( (trg and rClk.updated) = '1' ) then
      v.updated  := '0';
      v.strobe   := not rClk.strobe;
      v.pulseid  := rClk.pulseidReg;
    end if;

    rinClk <= v;
  end process P_CLK_COMB;

  P_OCLK_COMB : process( rOClk, synErr, wdgStb, strobe ) is
    variable v : RegOClkType;
  begin

    v := rOClk;

    -- watchdog
    if ( PULSEID_WDOG_P_G > 0 ) then
      if    ( wdgStb = '1' ) then
        v.wdgStrobe := PULSEID_WDOG_P_G;
      elsif ( rOClk.wdgStrobe = 0 ) then 
        v.wdgStrobe := PULSEID_WDOG_P_G;
        v.wdgErrors := rOClk.wdgErrors + 1;
      else
        v.wdgStrobe := rOClk.wdgStrobe - 1;
      end if;
    end if;

    if ( synErr = '1' ) then
      v.synErrors := rOClk.synErrors + 1;
    end if;

    if ( strobe = '1' ) then
      v.pulseidCnt := rOClk.pulseidCnt + 1;
    end if;

    rinOClk <= v;
  end process P_OCLK_COMB;

  P_CLK_SEQ : process ( clk ) is 
  begin
    if ( rising_edge( clk ) ) then
      if ( rst = '1' ) then
        rClk <= REG_CLK_INIT_C;
      else
        rClk <= rinClk;
      end if;
    end if;
  end process P_CLK_SEQ;

  P_OCLK_SEQ : process ( oclk ) is 
  begin
    if ( rising_edge( oclk ) ) then
      if ( orst = '1' ) then
        rOClk <= REG_OCLK_INIT_C;
      else
        rOClk <= rinOClk;
      end if;
    end if;
  end process P_OCLK_SEQ;

  pulseid       <= rClk.pulseid;
  synErrors     <= std_logic_vector(rOClk.synErrors );
  wdgErrors     <= std_logic_vector(rOClk.wdgErrors );
  pulseidCnt    <= std_logic_vector(rOClk.pulseidCnt);
  pulseidStrobe <= strobe;

end architecture rtl;
