library ieee;

use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- assumes addresses are presented in ascending order
entity PulseidExtractor is
  generic (
    PULSEID_OFFSET_G  : natural := 0;    -- byte-offset in data memory
    PULSEID_BIGEND_G  : boolean := true; -- endian-ness
    PULSEID_LENGTH_G  : natural := 8;    -- in bytes
    USE_ASYNC_OUTP_G  : boolean := true
  );
  port (
    clk               : in  std_logic;
    rst               : in  std_logic;
    streamData        : in  std_logic_vector( 7 downto 0);
    streamAddr        : in  std_logic_vector(10 downto 0);
    streamValid       : in  std_logic;
    oclk              : in  std_logic := '0';
    orst              : in  std_logic := '0';
    pulseid           : out std_logic_vector(8*PULSEID_LENGTH_G - 1 downto 0);
    pulseidStrobe     : out std_logic -- asserted for 1 cycle when a new ID is registered on 'pulseid'
  );
end entity PulseidExtractor;

architecture rtl of PulseidExtractor is

  type DemuxType is array (natural range 0 to PULSEID_LENGTH_G - 2) of std_logic_vector(7 downto 0);

  type RegType is record
    demux   : DemuxType;
    pulseid : std_logic_vector(8*PULSEID_LENGTH_G     - 1 downto 0);
    strobe  : std_logic;
  end record RegType;

  constant REG_INIT_C : RegType := (
    demux   => (others => (others => '0')),
    pulseid => (others => '0'),
    strobe  => '0'
  );

  constant   STAGES_C  : natural := 2;

  attribute  KEEP      : string;
  attribute  ASYNC_REG : string;

  signal pulseid_o     : std_logic_vector(8*PULSEID_LENGTH_G - 1 downto 0);
  signal strobe_o      : std_logic_vector(STAGES_C           - 1 downto 0) := (others => '0');

  attribute ASYNC_REG of strobe_o  : signal is "TRUE";
  attribute KEEP      of strobe_o  : signal is "TRUE";
  attribute KEEP      of pulseid_o : signal is "TRUE";

  signal r   : RegType := REG_INIT_C;
  signal rin : RegType;

begin

  G_Async : if ( USE_ASYNC_OUTP_G ) generate
    P_SYNC : process ( oclk ) is
    begin
      if ( rising_edge( oclk ) ) then
        if ( orst = '1' ) then
          strobe_o <= (others => '0');
        else
          strobe_o <= strobe_o( strobe_o'left - 1 downto strobe_o'right) & r.strobe;
        end if;
      end if;
    end process P_SYNC;

    pulseIdStrobe <= strobe_o( strobe_o'left );
  end generate G_Async;

  G_Sync : if ( not USE_ASYNC_OUTP_G ) generate
    pulseIdStrobe <= r.strobe;
  end generate G_Sync;

  P_COMB : process( r, streamData, streamAddr, streamValid ) is
    variable v        : RegType;
    variable offset   : signed(streamAddr'left + 1 downto streamAddr'right);
    constant END_OFF  : natural := PULSEID_LENGTH_G - 1;
    variable demuxVec : std_logic_vector( 8*v.demux'length - 1 downto 0 );
  begin
    v := r;
    v.strobe := '0';
	if ( streamValid = '1' ) then
      offset := signed(resize(unsigned(streamAddr),offset'length)) - PULSEID_OFFSET_G;
      if ( offset >= 0 ) then
        if ( offset < END_OFF ) then
          if ( PULSEID_BIGEND_G ) then
            v.demux(v.demux'right - to_integer(offset)) := streamData;
          else
            v.demux(to_integer(offset))                 := streamData;
          end if;
        elsif ( offset = END_OFF ) then
          for i in v.demux'range loop
            demuxVec( 8*i + 7 downto 8* i) := r.demux(i);
          end loop;

          if ( PULSEID_BIGEND_G ) then
            v.pulseid := demuxVec & streamData;
          else
            v.pulseid := streamData & demuxVec;
          end if;

          v.strobe := '1';
        end if; -- offset <= END_OFF
      end if; -- offset >= 0
    end if; -- streamValid = '1'
    rin <= v;
  end process P_COMB;

  P_SEQ : process ( clk ) is 
  begin
    if ( rising_edge( clk ) ) then
      if ( rst = '1' ) then
        r <= REG_INIT_C;
      else
        r <= rin;
      end if;
    end if;
  end process P_SEQ;

  pulseid_o <= r.pulseid;
  pulseid   <= pulseid_o;

end architecture rtl;
