library ieee;

use ieee.std_logic_1164.all;

-- compare two slowly changing values and synchronize
-- equality into a destination clock domain
-- signals are assumed to change slowly compared to destination clock

entity SyncCmpSlow is
  generic (
    DATA_WIDTH_G    : positive;
    -- >0 generate one dstClk cycle pulse on positive edge
    -- <0 generate one dstClk cycle pulse on negative edge
    -- =0 synchronize level to dstClk
    EDGE_G          : integer               := 0;
    STAGES_G        : positive range 2 to 3 := 2;
    INITVAL_G       : std_logic             := '0'
  );
  port (
    srcClk          : in  std_logic;
    srcRst          : in  std_logic;
    srcDataA        : in  std_logic_vector(DATA_WIDTH_G - 1 downto 0);
    srcDataB        : in  std_logic_vector(DATA_WIDTH_G - 1 downto 0);

    dstClk          : in  std_logic;
    dstRst          : in  std_logic;
    dstData         : out std_logic
  );
end entity SyncCmpSlow;

architecture rtl of SyncCmpSlow is
  attribute ASYNC_REG : string;
  attribute KEEP      : string;

  function EDGE_STAGES_F return natural is
  begin
    if ( EDGE_G = 0 ) then return 0; else return 1; end if;
  end function EDGE_STAGES_F;

  constant STAGES_C   : positive := STAGES_G + EDGE_STAGES_F;

  signal    syncCmp   : std_logic_vector(STAGES_C - 1 downto 0) := (others => INITVAL_G);
  signal    capture   : std_logic                               := INITVAL_G;

  attribute ASYNC_REG of syncCmp : signal is "TRUE";
  attribute KEEP      of syncCmp : signal is "TRUE";

  signal    asynRst   : std_logic;

begin

  asynRst <= srcRst or dstRst;

  P_CAP : process( srcClk, asynRst ) is
  begin
    if ( asynRst = '1' ) then
      capture <= INITVAL_G;
    elsif ( rising_edge( srcClk ) ) then
      if ( srcDataA = srcDataB ) then
        capture <= '1';
      else
        capture <= '0';
      end if;
    end if;
  end process P_CAP;

  P_SYNC : process( dstClk, asynRst ) is
  begin
    if ( asynRst = '1' ) then
      syncCmp <= (others => INITVAL_G);
    elsif ( rising_edge( dstClk ) ) then
      syncCmp <= syncCmp(syncCmp'left - 1 downto syncCmp'right) & capture;
    end if;
  end process P_SYNC;

  G_POSEDGE : if ( EDGE_G > 0 ) generate
    dstData <= ((not syncCmp(syncCmp'left)) and (    syncCmp(syncCmp'left - 1)));
  end generate G_POSEDGE;

  G_NEGEDGE : if ( EDGE_G < 0 ) generate
    dstData <= ((    syncCmp(syncCmp'left)) and (not syncCmp(syncCmp'left - 1)));
  end generate G_NEGEDGE;

  G_LEVEL   : if ( EDGE_G = 0 ) generate
    dstData <= syncCmp(syncCmp'left);
  end generate G_LEVEL;

end architecture rtl;
