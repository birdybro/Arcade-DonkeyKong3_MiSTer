--
-- T80as_ce : synchronous clock-enable edition of T80as (for the DK3 clock rework)
--
-- T80as ("asynchronous top level") generates its bus-control signals (DI_Reg,
-- WR_n, RD/MREQ/IORQ, the inhibit terms, Wait_s) on the FALLING edge of CLK_n
-- and does NOT gate them with CEN. That is correct only when CLK_n is itself the
-- ~4 MHz CPU clock. On the single 98.304 MHz master clock those processes would
-- run every master cycle instead of at the CPU rate, malforming every bus cycle.
--
-- This variant runs entirely on the rising edge of the master CLK_n and uses two
-- clock-enables to reconstruct the original two-phase behaviour:
--   CEN_p  = cen_cpu   (the "posedge 4 MHz" instant) -> T80 state machine
--   CEN_n  = cen_cpu_n (the "negedge 4 MHz" instant) -> bus-control processes
-- CEN_p and CEN_n strictly alternate (cen_cpu_n is a half CPU period after
-- cen_cpu), so the posedge-state / negedge-bus interleaving of the real Z80 is
-- preserved. Logic is otherwise identical to T80as.
--
library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;
use work.T80_Pack.all;

entity T80as_ce is
	generic(
		Mode : integer := 0	-- 0 => Z80, 1 => Fast Z80, 2 => 8080, 3 => GB
	);
	port(
		RESET_n		: in std_logic;
		CLK_n		: in std_logic;
		CEN_p		: in std_logic;	-- state-machine enable  (cen_cpu)
		CEN_n		: in std_logic;	-- bus-control enable    (cen_cpu_n)
		WAIT_n		: in std_logic;
		INT_n		: in std_logic;
		NMI_n		: in std_logic;
		BUSRQ_n		: in std_logic;
		M1_n		: out std_logic;
		MREQ_n		: out std_logic;
		IORQ_n		: out std_logic;
		RD_n		: out std_logic;
		WR_n		: out std_logic;
		RFSH_n		: out std_logic;
		HALT_n		: out std_logic;
		BUSAK_n		: out std_logic;
		A			: out std_logic_vector(15 downto 0);
		DI			: in  std_logic_vector(7 downto 0);
		DO			: out std_logic_vector(7 downto 0);
		DOE			: out std_logic
	);
end T80as_ce;

architecture rtl of T80as_ce is

	signal Reset_s		: std_logic;
	signal IntCycle_n	: std_logic;
	signal IORQ			: std_logic;
	signal NoRead		: std_logic;
	signal Write		: std_logic;
	signal MREQ			: std_logic;
	signal MReq_Inhibit	: std_logic;
	signal Req_Inhibit	: std_logic;
	signal RD			: std_logic;
	signal MREQ_n_i		: std_logic;
	signal IORQ_n_i		: std_logic;
	signal RD_n_i		: std_logic;
	signal WR_n_i		: std_logic;
	signal RFSH_n_i		: std_logic;
	signal BUSAK_n_i	: std_logic;
	signal A_i			: std_logic_vector(15 downto 0);
	signal DI_Reg		: std_logic_vector (7 downto 0);	-- Input synchroniser
	signal Wait_s		: std_logic;
	signal MCycle		: std_logic_vector(2 downto 0);
	signal TState		: std_logic_vector(2 downto 0);

begin

	BUSAK_n <= BUSAK_n_i;
	MREQ_n_i <= not MREQ or (Req_Inhibit and MReq_Inhibit);
	RD_n_i <= not RD or Req_Inhibit;

	MREQ_n <= MREQ_n_i;
	IORQ_n <= IORQ_n_i;
	RD_n <= RD_n_i;
	WR_n <= WR_n_i;
	RFSH_n <= RFSH_n_i;
	A <= A_i;
	DOE <= Write when BUSAK_n_i = '1' else '0';

	process (RESET_n, CLK_n)
	begin
		if RESET_n = '0' then
			Reset_s <= '0';
		elsif rising_edge(CLK_n) then
			Reset_s <= '1';
		end if;
	end process;

	u0 : T80
		generic map(
			Mode => Mode,
			IOWait => 1)
		port map(
			CEN => CEN_p,
			M1_n => M1_n,
			IORQ => IORQ,
			NoRead => NoRead,
			Write => Write,
			RFSH_n => RFSH_n_i,
			HALT_n => HALT_n,
			WAIT_n => Wait_s,
			INT_n => INT_n,
			NMI_n => NMI_n,
			RESET_n => Reset_s,
			BUSRQ_n => BUSRQ_n,
			BUSAK_n => BUSAK_n_i,
			CLK_n => CLK_n,
			A => A_i,
			DInst => DI,
			DI => DI_Reg,
			DO => DO,
			MC => MCycle,
			TS => TState,
			IntCycle_n => IntCycle_n);

	-- DI input synchroniser + WAIT latch (was negedge CLK_n) -> CEN_n
	process (CLK_n)
	begin
		if rising_edge(CLK_n) then
			if CEN_n = '1' then
				Wait_s <= WAIT_n;
				if TState = "011" and BUSAK_n_i = '1' then
					DI_Reg <= to_x01(DI);
				end if;
			end if;
		end if;
	end process;

	-- WR_n (was negedge CLK_n) -> CEN_n
	process (Reset_s, CLK_n)
	begin
		if Reset_s = '0' then
			WR_n_i <= '1';
		elsif rising_edge(CLK_n) then
			if CEN_n = '1' then
				WR_n_i <= '1';
				if TState = "010" then
					WR_n_i <= not Write;
				end if;
			end if;
		end if;
	end process;

	-- Req_Inhibit (was rising edge, ungated) -> CEN_p
	process (Reset_s, CLK_n)
	begin
		if Reset_s = '0' then
			Req_Inhibit <= '0';
		elsif rising_edge(CLK_n) then
			if CEN_p = '1' then
				if MCycle = "001" and TState = "010" then
					Req_Inhibit <= '1';
				else
					Req_Inhibit <= '0';
				end if;
			end if;
		end if;
	end process;

	-- MReq_Inhibit (was negedge CLK_n) -> CEN_n
	process (Reset_s, CLK_n)
	begin
		if Reset_s = '0' then
			MReq_Inhibit <= '0';
		elsif rising_edge(CLK_n) then
			if CEN_n = '1' then
				if MCycle = "001" and TState = "010" then
					MReq_Inhibit <= '1';
				else
					MReq_Inhibit <= '0';
				end if;
			end if;
		end if;
	end process;

	-- RD / MREQ / IORQ (was negedge CLK_n) -> CEN_n
	process(Reset_s, CLK_n)
	begin
		if Reset_s = '0' then
			RD <= '0';
			IORQ_n_i <= '1';
			MREQ <= '0';
		elsif rising_edge(CLK_n) then
			if CEN_n = '1' then
				if MCycle = "001" then
					if TState = "001" then
						RD <= IntCycle_n;
						MREQ <= IntCycle_n;
						IORQ_n_i <= IntCycle_n;
					end if;
					if TState = "011" then
						RD <= '0';
						IORQ_n_i <= '1';
						MREQ <= '1';
					end if;
					if TState = "100" then
						MREQ <= '0';
					end if;
				else
					if TState = "001" and NoRead = '0' then
						RD <= not Write;
						IORQ_n_i <= not IORQ;
						MREQ <= not IORQ;
					end if;
					if TState = "011" then
						RD <= '0';
						IORQ_n_i <= '1';
						MREQ <= '0';
					end if;
				end if;
			end if;
		end if;
	end process;

end;
