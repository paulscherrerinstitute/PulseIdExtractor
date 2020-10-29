library ieee;

use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.LedStripTcsrWrapperPkg.all;

entity PulseidExtractorTb is
end entity PulseidExtractorTb;

architecture rtl of PulseidExtractorTb is
  constant OFF  : natural := 4;
  constant LEN  : natural := 8;
  signal   addr : unsigned(10 downto 0)        := (others => '0');

  signal   stm  : EvrStreamType := (
    addr  => (others => '0'),
    data  => (others => 'X'),
    valid => '0'
  );

  signal   clk  : std_logic                    := '0';
  signal   rst  : std_logic                    := '1';
  signal   trg  : std_logic                    := '0';

  signal run         : boolean                 := true;

  type OkType   is array (boolean) of boolean;
  type Slv32BA  is array (boolean) of std_logic_vector(31 downto 0);

  signal ok          : OkType := (others => false);
  signal synErrors   : Slv32BA;
  signal wdgErrors   : Slv32BA;

  signal cnt         : natural                 := 0;

  subtype PidType is std_logic_vector(8*LEN - 1 downto 0);

  type PidArray is array (natural range 0 to LEN - 1) of std_logic_vector(7 downto 0);

  constant PID_C  : PidArray := (
    0 => x"01",
    1 => x"a0",
    2 => x"02",
    3 => x"b0",
    4 => x"03",
    5 => x"c0",
    6 => x"04",
    7 => x"d0"
  );

begin

  P_CLK : process is
  begin
    if ( run ) then
      wait for 10 ns;
      clk <= not clk;
    else
      wait;
    end if;
  end process P_CLK;

  P_MUX : process (addr, stm) is
  begin
    if ( stm.valid = '1' and (addr >= OFF) and (addr < OFF + LEN) ) then
      stm.data <= PID_C( to_integer( addr - OFF ) );
    else
      stm.data <= (others => 'X');
    end if;
  end process P_MUX;

  P_CNT : process ( clk ) is
    variable passed : boolean;
  begin
    if ( rising_edge( clk ) ) then
      cnt <= cnt + 1;
      if ( cnt = 5 ) then
        rst <= '0';
      end if;
    end if;
  end process P_CNT;

  P_DRV : process is

    variable passed : boolean;

    procedure tick is
    begin
      wait until ( rising_edge( clk ) );
    end procedure tick;

  begin
    while ( rst = '1' ) loop
      tick;
    end loop;
    
    while ( addr < OFF + LEN + 4 ) loop
      if ((cnt mod 2 ) = 1) then
        addr      <= addr + 1;
        stm.valid <= '1';
      end if;
      tick;
    end loop;

    trg <= '1';
    tick;
    stm.valid <= '0';

    while ( cnt < 64 ) loop
      tick;
    end loop;

    passed := true;
    for endian in ok'range loop
      passed := passed and ok(endian);
      report "Test for BE=" & boolean'image(endian) & " passed => " & boolean'image(ok(endian));
    end loop;

    addr      <= to_unsigned(OFF + 1, addr'length);
    stm.valid <= '1';
    tick;
    while ( addr < OFF + LEN + 4 ) loop
      if ((cnt mod 2 ) = 1) then
        addr      <= addr + 1;
      end if;
      tick;
    end loop;
    stm.valid <= '0';
    tick;

    for endian in ok'range loop
      passed := passed and ( unsigned(synErrors(endian)) = 1 );
      report "SynError reading for BE=" & boolean'image(endian) & " : " & integer'image(to_integer(unsigned(synErrors(endian))));
      passed := passed and ( unsigned(wdgErrors(endian)) = 0 );
      report "WdgError reading for BE=" & boolean'image(endian) & " : " & integer'image(to_integer(unsigned(wdgErrors(endian))));
    end loop;

    while ( cnt < 200 ) loop
      tick;
    end loop;

    for endian in ok'range loop

      passed := passed and ( unsigned(wdgErrors(endian)) > 0 );
      report "WdgError reading for BE=" & boolean'image(endian) & " : " & integer'image(to_integer(unsigned(wdgErrors(endian))));
    end loop;


    if ( passed ) then
      report "Test PASSED";
    else
      report "Test FAILED" severity failure;
    end if;
    tick;
    run <= false;
    tick;
  end process P_DRV;

  G_DUT : for endianBig in ok'range generate
    signal pid  : PidType;
    signal strb : std_logic;
    signal trig : std_logic;
  begin

  trig <= trg when endianBig else '1';

  stm.addr <= std_logic_vector(addr);

  U_DUT : entity work.PulseidExtractor
    generic map (
      PULSEID_OFFSET_G => OFF,
      PULSEID_LENGTH_G => LEN,
      PULSEID_BIGEND_G => endianBig,
      USE_ASYNC_OUTP_G => false,
      PULSEID_WDOG_P_G => 100
    )
    port map (
      clk              => clk,
      rst              => rst,
      trg              => trig,

      evrStream        => stm,

      synErrors        => synErrors(endianBig),
      wdgErrors        => wdgErrors(endianBig),

      pulseid          => pid,
      pulseidStrobe    => strb
    );

  P_CHK : process ( clk ) is
    type ExpectedPidArray is array(boolean) of PidType;

    constant EXPECTED : ExpectedPidArray := (
      true  => x"01a002b003c004d0",
      false => x"d004c003b002a001"
    );

  begin
    if ( rising_edge( clk ) ) then
      if ( rst = '0' ) then
        if ( strb = '1' ) then
          ok(endianBig) <= (EXPECTED(endianBig) = pid);
        end if;
      end if;
    end if;
  end process P_CHK;
  end generate G_DUT;
end architecture rtl;

