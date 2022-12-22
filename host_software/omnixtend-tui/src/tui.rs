/*
    SPDX-License-Identifier: Apache License 2.0

    SPDX-FileCopyrightText: 2022 Western Digital Corporation or its affiliates.

    Author: Jaco Hofmann (jaco.hofmann@wdc.com)
*/

use crate::InvalidMacSnafu;
use crate::ParseIntSnafu;
use crate::RegexSnafu;
use crate::Result;
use crate::{Error, IOSnafu};
use crossterm::event::poll;
use crossterm::event::DisableMouseCapture;
use crossterm::event::EnableMouseCapture;
use crossterm::event::Event;
use crossterm::event::KeyCode;
use crossterm::event::{self, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::disable_raw_mode;
use crossterm::terminal::enable_raw_mode;
use crossterm::terminal::EnterAlternateScreen;
use crossterm::terminal::LeaveAlternateScreen;
use omnixtend_rs::cache::CacheStatus;
use omnixtend_rs::connection::ConnectionState;
use omnixtend_rs::tilelink_messages::OmnixtendPermissionChangeCap;
use parking_lot::{Mutex, RwLock, RwLockReadGuard, RwLockWriteGuard};
use pnet::util::MacAddr;
use regex::Regex;
use snafu::ResultExt;
use std::convert::TryInto;
use std::io::{self, stdout, Stdout};
use std::panic;
use std::str::FromStr;
use std::time::Duration;
use time::macros::format_description;
use time::macros::offset;
use time::OffsetDateTime;
use time::UtcOffset;
use tui::layout::Constraint;
use tui::layout::Direction;
use tui::layout::Layout;
use tui::style::{Color, Style};
use tui::text::Span;
use tui::text::Spans;
use tui::text::Text;
use tui::widgets::List;
use tui::widgets::ListItem;
use tui::widgets::ListState;
use tui::widgets::{Block, Borders, Cell, Paragraph, Row, Table};
use tui::Frame;
use tui::{backend::CrosstermBackend, Terminal};

pub struct Tui {
    term: Mutex<Terminal<CrosstermBackend<Stdout>>>,
    log: RwLock<Vec<(String, Style)>>,
    cmdline_data: RwLock<Cmdline>,
    tz_offset: UtcOffset,
}

struct Cmdline {
    cmdline: Vec<String>,
    cmdline_selected: usize,
    cursor: usize,
}

impl Cmdline {
    fn new() -> Self {
        Self {
            cmdline: vec![String::new()],
            cmdline_selected: 0,
            cursor: 0,
        }
    }

    fn char(&mut self, c: char) {
        self.cmdline[self.cmdline_selected].insert(self.cursor, c);
        self.cursor += 1;
    }

    fn backspace(&mut self) {
        if self.cursor > 0 {
            self.cmdline[self.cmdline_selected].remove(self.cursor - 1);
            self.cursor -= 1;
        }
    }

    fn del(&mut self) {
        if self.cursor < self.cmdline[self.cmdline_selected].len() {
            self.cmdline[self.cmdline_selected].remove(self.cursor);
        }
    }

    fn home(&mut self) {
        self.cursor = 0;
    }

    fn end(&mut self) {
        self.cursor = self.cmdline[self.cmdline_selected].len();
    }

    fn up(&mut self) {
        if self.cmdline_selected > 0 {
            self.cmdline_selected -= 1;
            self.cursor = self.cmdline[self.cmdline_selected].len();
        }
    }

    fn left(&mut self) {
        if self.cursor > 0 {
            self.cursor -= 1;
        }
    }

    fn right(&mut self) {
        if self.cursor < self.cmdline[self.cmdline_selected].len() {
            self.cursor += 1;
        }
    }

    fn down(&mut self) {
        if self.cmdline_selected + 1 < self.cmdline.len() {
            self.cmdline_selected += 1;
            self.cursor = self.cmdline[self.cmdline_selected].len();
        } else if !self.cmdline[self.cmdline_selected].is_empty() {
            self.cmdline.push(String::new());
            self.cmdline_selected += 1;
            self.cursor = self.cmdline[self.cmdline_selected].len();
        }
    }

    fn new_line(&mut self) {
        self.cmdline_selected = self.cmdline.len() - 1;
        if !self.cmdline[self.cmdline_selected].is_empty() {
            self.cmdline.push("".to_string());
            self.cmdline_selected += 1;
        }
        self.cursor = 0;
    }

    fn get(&self) -> (String, usize) {
        (
            format!("{} ", self.cmdline[self.cmdline_selected].clone()),
            self.cursor,
        )
    }
}

pub struct TuiConnectionState {
    pub addr: u64,
    pub size: u64,
    pub mac: MacAddr,
    pub state: ConnectionState,
    pub outstanding: u64,
    pub rx_seq: u64,
    pub tx_seq: u64,
    pub we_acked: u64,
    pub they_acked: u64,
    pub last_msg_in_micros: Duration,
    pub last_msg_out_micros: Duration,
}

#[derive(PartialEq, Debug, Clone, Copy)]
pub enum CmdlineEvents {
    Quit,
    Connect(MacAddr),
    Disconnect(MacAddr),
    None,
    Read(u64),
    Write(u64, u64),
    CacheRelease(u64),
    CacheReleaseAll,
    CacheRead(u64),
    CacheWrite(u64, u64),
    Help,
}

impl Drop for Tui {
    fn drop(&mut self) {
        Self::drop_inner();
    }
}

impl Tui {
    fn drop_inner() {
        // Exits raw mode.
        disable_raw_mode().unwrap_or_else(|e| error!("Could not set raw mode: {:?}", e));
        execute!(stdout(), LeaveAlternateScreen, DisableMouseCapture)
            .unwrap_or_else(|e| error!("Could not reset terminal: {:?}", e));
    }

    pub fn new() -> Result<Self> {
        better_panic::install();

        Self::setup_panic_hook();

        let offset = if let Ok(t) = OffsetDateTime::now_local() {
            t.offset()
        } else {
            offset!(UTC)
        };

        let mut stdout = io::stdout();
        execute!(stdout, EnterAlternateScreen, EnableMouseCapture).context(IOSnafu)?;
        let backend = CrosstermBackend::new(stdout);
        let terminal = Terminal::new(backend).context(IOSnafu)?;
        enable_raw_mode().context(IOSnafu)?;

        Ok(Self {
            tz_offset: offset,
            term: Mutex::new(terminal),
            cmdline_data: RwLock::new(Cmdline::new()),
            log: RwLock::new(Vec::new()),
        })
    }

    fn setup_panic_hook() {
        panic::set_hook(Box::new(|panic_info| {
            Self::drop_inner();
            better_panic::Settings::auto().create_panic_handler()(panic_info);
        }));
    }

    pub fn draw(
        &self,
        fps: f64,
        eventsps: u64,
        constates: &[TuiConnectionState],
        cachestates: &[CacheStatus],
    ) -> Result<()> {
        let (cmdline, cursor) = self.get_cmdline_read()?.get();
        let v = self.get_log_read()?.clone();

        self.term
            .lock()
            .draw(|f| {
                Self::draw_inner(
                    f,
                    &v,
                    &cmdline,
                    cursor,
                    fps,
                    eventsps,
                    constates,
                    cachestates,
                )
                .unwrap();
            })
            .context(IOSnafu)
            .map(|_v| ())
    }

    fn draw_inner<'a>(
        f: &mut Frame<CrosstermBackend<Stdout>>,
        log: &Vec<(String, Style)>,
        cmdline: &str,
        cursor: usize,
        fps: f64,
        eventsps: u64,
        constates: &[TuiConnectionState],
        cachestates: &[CacheStatus],
    ) -> Result<()> {
        let chunks_v = Layout::default()
            .direction(Direction::Vertical)
            .constraints(
                [
                    Constraint::Length(f.size().height - 3),
                    Constraint::Length(2),
                    Constraint::Length(1),
                ]
                .as_ref(),
            )
            .split(f.size());

        f.render_widget(Self::render_commandline(cmdline, cursor)?, chunks_v[1]);

        f.render_widget(Self::render_help(fps, eventsps)?, chunks_v[2]);

        let chunks_h = Layout::default()
            .direction(Direction::Horizontal)
            .constraints([Constraint::Percentage(60), Constraint::Percentage(40)])
            .split(chunks_v[0]);

        let mut logrender = Self::render_log(chunks_h[0].width - 2, &log)?;
        f.render_stateful_widget(logrender.0, chunks_h[0], &mut logrender.1);

        let chunks_status = Layout::default()
            .direction(Direction::Vertical)
            .constraints([Constraint::Percentage(50), Constraint::Percentage(50)].as_ref())
            .split(chunks_h[1]);

        f.render_widget(Self::render_connectionstatus(constates)?, chunks_status[0]);

        f.render_widget(Self::render_cachestatus(cachestates)?, chunks_status[1]);

        Ok(())
    }

    pub fn log_message(&self, msg: &str, level: log::Level) -> Result<()> {
        let logcolor = match level {
            log::Level::Error => Color::Red,
            log::Level::Warn => Color::Magenta,
            log::Level::Info => Color::Reset,
            log::Level::Debug => Color::LightGreen,
            log::Level::Trace => Color::Gray,
        };
        self.get_log_write()?.push((
            format!(
                "{}:{:?} => {}",
                OffsetDateTime::now_utc()
                    .to_offset(self.tz_offset)
                    .format(format_description!(
                        "[hour]:[minute]:[second](UTC[offset_hour sign:mandatory]:[offset_minute])"
                    ))
                    .unwrap_or("NO_TIME".to_string()),
                level,
                msg
            ),
            Style::default().fg(logcolor),
        ));
        Ok(())
    }

    fn get_log_read<'a>(&'a self) -> Result<RwLockReadGuard<'a, Vec<(String, Style)>>> {
        Ok(self.log.read())
    }

    fn get_log_write<'a>(&'a self) -> Result<RwLockWriteGuard<'a, Vec<(String, Style)>>> {
        Ok(self.log.write())
    }

    fn get_cmdline_read<'a>(&'a self) -> Result<RwLockReadGuard<'a, Cmdline>> {
        Ok(self.cmdline_data.read())
    }

    fn get_cmdline_write<'a>(&'a self) -> Result<RwLockWriteGuard<'a, Cmdline>> {
        Ok(self.cmdline_data.write())
    }

    fn process_message(&self) -> Result<CmdlineEvents> {
        let mut event = CmdlineEvents::None;
        let (cmdline, _) = self.get_cmdline_read()?.get();
        let cmdline = cmdline.trim();
        match cmdline.split_whitespace().next().unwrap_or_default() {
            "quit" | "q" => event = CmdlineEvents::Quit,
            "c" | "connect" => {
                let mac = Self::get_mac(&cmdline)?;
                event = CmdlineEvents::Connect(mac);
            }
            "d" | "disconnect" => {
                let mac = Self::get_mac(&cmdline)?;
                event = CmdlineEvents::Disconnect(mac);
            }
            "w" | "write" => {
                let (addr, data) = Self::get_write(&cmdline)?;
                event = CmdlineEvents::Write(addr, data);
            }
            "r" | "read" => {
                let addr = Self::get_read(&cmdline)?;
                event = CmdlineEvents::Read(addr);
            }
            "cw" | "cwrite" => {
                let (addr, data) = Self::get_write(&cmdline)?;
                event = CmdlineEvents::CacheWrite(addr, data);
            }
            "cr" | "cread" => {
                let addr = Self::get_read(&cmdline)?;
                event = CmdlineEvents::CacheRead(addr);
            }
            "cd" | "cdestroy" => {
                let addr = Self::get_read(&cmdline)?;
                event = CmdlineEvents::CacheRelease(addr);
            }
            "cda" | "cdestroyall" => {
                event = CmdlineEvents::CacheReleaseAll;
            }
            "h" | "help" => {
                event = CmdlineEvents::Help;
            }
            _ => {}
        }
        if event != CmdlineEvents::None {
            self.get_cmdline_write()?.new_line();
        }
        Ok(event)
    }

    pub fn events(&self) -> Result<CmdlineEvents> {
        let mut event = CmdlineEvents::None;
        if poll(Duration::from_millis(0)).context(IOSnafu)? {
            if let Event::Key(key) = event::read().context(IOSnafu)? {
                match key.code {
                    KeyCode::Enter => event = self.process_message()?,
                    KeyCode::Char('c') if key.modifiers == KeyModifiers::CONTROL => {
                        event = CmdlineEvents::Quit
                    }
                    KeyCode::Char(c) => {
                        self.get_cmdline_write()?.char(c);
                    }
                    KeyCode::Down => {
                        self.get_cmdline_write()?.down();
                    }
                    KeyCode::Up => {
                        self.get_cmdline_write()?.up();
                    }
                    KeyCode::Left => {
                        self.get_cmdline_write()?.left();
                    }
                    KeyCode::Right => {
                        self.get_cmdline_write()?.right();
                    }
                    KeyCode::Backspace => {
                        self.get_cmdline_write()?.backspace();
                    }
                    KeyCode::Delete => {
                        self.get_cmdline_write()?.del();
                    }
                    KeyCode::Home => {
                        self.get_cmdline_write()?.home();
                    }
                    KeyCode::End => {
                        self.get_cmdline_write()?.end();
                    }
                    _ => {}
                }
            }
        }
        Ok(event)
    }

    fn get_write(s: &str) -> Result<(u64, u64)> {
        let re = Regex::new(r".*0x([0-9A-Za-z]+).*0x([0-9A-Za-z]+)").context(RegexSnafu)?;
        let c = re
            .captures(s)
            .ok_or(Error::InvalidWriteRegex { s: s.to_string() })?;
        let addr = c
            .get(1)
            .ok_or(Error::InvalidAddrRegex { s: s.to_string() })?
            .as_str();
        let data = c
            .get(2)
            .ok_or(Error::InvalidDataRegex { s: s.to_string() })?
            .as_str();

        Ok((
            u64::from_str_radix(addr, 16).context(ParseIntSnafu)?,
            u64::from_str_radix(data, 16).context(ParseIntSnafu)?,
        ))
    }

    fn get_read(s: &str) -> Result<u64> {
        let re = Regex::new(r".*0x([0-9A-Za-z]+)").context(RegexSnafu)?;
        let c = re
            .captures(s)
            .ok_or(Error::InvalidWriteRegex { s: s.to_string() })?;
        let addr = c
            .get(1)
            .ok_or(Error::InvalidAddrRegex { s: s.to_string() })?
            .as_str();

        Ok(u64::from_str_radix(addr, 16).context(ParseIntSnafu)?)
    }

    fn get_mac(s: &str) -> Result<MacAddr> {
        let re = Regex::new(r".*((?:[a-zA-Z0-9]{2}.?){6}).*").context(RegexSnafu)?;
        let c = re
            .captures(s)
            .ok_or(Error::InvalidMacRegex { s: s.to_string() })?;
        let mac = c
            .get(1)
            .ok_or(Error::InvalidMacRegex { s: s.to_string() })?
            .as_str();
        MacAddr::from_str(mac).context(InvalidMacSnafu)
    }

    fn render_cachestatus(cachestates: &[CacheStatus]) -> Result<Table> {
        let header = Row::new(vec!["Address", "Modified", "Permission", "Data"]);
        let mut cacheinfo = Vec::new();
        for c in cachestates {
            let statestyle = match c.permissions {
                OmnixtendPermissionChangeCap::ToT => Color::Red,
                OmnixtendPermissionChangeCap::ToB => Color::Green,
                OmnixtendPermissionChangeCap::ToN => Color::Gray,
            };
            let statename = match c.permissions {
                OmnixtendPermissionChangeCap::ToT => "Trunk",
                OmnixtendPermissionChangeCap::ToB => "Branch",
                OmnixtendPermissionChangeCap::ToN => "None",
            };

            cacheinfo.push(Row::new(vec![
                Cell::from(format!("{:#010X}", c.addr)),
                Cell::from(if c.modified { "M" } else { "C" }),
                Cell::from(statename).style(Style::default().fg(statestyle)),
                Cell::from(format!(
                    "{:#010X}",
                    u64::from_ne_bytes(c.data[..8].try_into().or(Err(Error::ConversionError {}))?)
                )),
            ]));
        }
        Ok(Table::new(cacheinfo)
            .header(header)
            .widths(&[
                Constraint::Length(10),
                Constraint::Length(10),
                Constraint::Length(10),
                Constraint::Length(10),
            ])
            .column_spacing(1)
            .style(Style::default())
            .block(Block::default().title("Cache Status").borders(Borders::ALL)))
    }

    fn render_connectionstatus(constates: &[TuiConnectionState]) -> Result<Table> {
        let mut coninfo = Vec::new();
        let header = Row::new(vec![
            "Mac/Address (Size)",
            "State",
            "TX/RX",
            "THEY/WE",
            "Out/Last",
        ]);
        for c in constates {
            let constyle = match c.state {
                ConnectionState::Active => Color::Green,
                ConnectionState::Idle => Color::Reset,
                ConnectionState::Enabled => Color::LightYellow,
                ConnectionState::Opened => Color::Yellow,
                ConnectionState::ClosedByHost => Color::LightRed,
                ConnectionState::ClosedByHostIndicated => Color::Red,
                ConnectionState::ClosedByClient => Color::Magenta,
            };
            coninfo.push(
                Row::new(vec![
                    Cell::from(format!(
                        "{}\n {:#010X} ({})",
                        c.mac,
                        c.addr,
                        human_bytes::human_bytes(c.size as f64)
                    )),
                    Cell::from(format!("{:?}", c.state)).style(Style::default().fg(constyle)),
                    Cell::from(format!("{}\n{}", c.tx_seq, c.rx_seq)),
                    Cell::from(format!("{}\n{}", c.they_acked, c.we_acked)),
                    Cell::from(format!(
                        "{}\nI:{:.2?}O:{:.2?}",
                        c.outstanding, c.last_msg_in_micros, c.last_msg_out_micros
                    )),
                ])
                .height(2),
            );
        }
        Ok(Table::new(coninfo)
            .header(header)
            .widths(&[
                Constraint::Length(6 * 2 + 5 + 4),
                Constraint::Length(6),
                Constraint::Length(6),
                Constraint::Length(6),
                Constraint::Length(20),
            ])
            .column_spacing(1)
            .style(Style::default())
            .block(Block::default().title("Connections").borders(Borders::ALL)))
    }

    fn render_commandline(cmdline: &str, cursor: usize) -> Result<Paragraph> {
        let str_before = &cmdline[0..cursor];
        let str_cursor = &cmdline[cursor..cursor + 1];
        let str_after = &cmdline[cursor + 1..];
        let cmdline_msg = vec![
            Span::raw("> "),
            Span::raw(str_before),
            Span::styled(str_cursor, Style::default().bg(Color::Gray)),
            Span::raw(str_after),
        ];
        Ok(Paragraph::new(Spans::from(cmdline_msg)).block(Block::default().title("Command")))
    }

    fn render_log<'a>(width: u16, log: &[(String, Style)]) -> Result<(List<'a>, ListState)> {
        let mut liststate = ListState::default();
        liststate.select(Some(if log.is_empty() { 0 } else { log.len() - 1 }));

        let listitems: Vec<ListItem> = log
            .iter()
            .map(|(text, style)| {
                let wrapped = textwrap::wrap(text, width as usize).join("\n");
                ListItem::new(wrapped).style(*style)
            })
            .collect();

        Ok((
            List::new(listitems).block(Block::default().title("Log").borders(Borders::ALL)),
            liststate,
        ))
    }

    fn render_help(fps: f64, eventps: u64) -> Result<Paragraph<'static>> {
        let help_text_msg = vec![
            Span::raw(format!("FPS {:.2} Events/s {} ", fps, eventps)),
            Span::raw(
                "Type quit or hit Ctrl-c to exit | (h)elp | (c)onnect | (d)isconnect | (r)ead | (w)rite | (cr)ead | (cw)rite | (cd)estroy | (cd)estroy(a)ll ",
            ),
        ];
        let text = Text::from(Spans::from(help_text_msg));
        Ok(Paragraph::new(text))
    }
}
