require "../minitest_helper"
require "../../src/krikri/plugin_helpers/mysql_privileges"

private alias Grant = Krikri::PluginHelpers::MysqlPrivileges::Grant

describe Krikri::PluginHelpers::MysqlPrivileges do
  include RaisesAssertion
  describe ".parse_spec" do
    include RaisesAssertion
    it "parses a single db.table:priv1,priv2 entry" do
      grants = Krikri::PluginHelpers::MysqlPrivileges.parse_spec("testdb.*:SELECT,INSERT")
      grants.must_equal([Grant.new("testdb.*", Set{"SELECT", "INSERT"})])
    end

    it "parses multiple grants separated by /" do
      grants = Krikri::PluginHelpers::MysqlPrivileges.parse_spec("db1.*:SELECT/db2.*:ALL")
      grants.must_equal([
        Grant.new("db1.*", Set{"SELECT"}),
        Grant.new("db2.*", Set{"ALL"}),
      ])
    end

    it "normalizes ALL PRIVILEGES to ALL" do
      grants = Krikri::PluginHelpers::MysqlPrivileges.parse_spec("db.*:ALL PRIVILEGES")
      grants.must_equal([Grant.new("db.*", Set{"ALL"})])
    end

    it "uppercases privilege names" do
      grants = Krikri::PluginHelpers::MysqlPrivileges.parse_spec("db.*:select,insert")
      grants.must_equal([Grant.new("db.*", Set{"SELECT", "INSERT"})])
    end

    it "raises on an entry with no : separator" do
      assert_raises_message(Exception, /invalid priv entry/) do
        Krikri::PluginHelpers::MysqlPrivileges.parse_spec("not-a-valid-entry")
      end
    end
  end

  # Real `SHOW GRANTS FOR user@host` output, captured from a live MariaDB
  # 11 server - see git log's mysql_user commits.
  describe ".parse_show_grants_line" do
    include RaisesAssertion
    it "parses the baseline GRANT USAGE identity row as a USAGE grant" do
      # Real community.mysql keeps the baseline row too (privileges_get):
      # the idempotency comparison needs it, since a spec of "*.*:USAGE"
      # resolves to exactly this entry.
      line = "GRANT USAGE ON *.* TO `demo4`@`%` IDENTIFIED BY PASSWORD '*14E65567ABDB5135D0CFD9A70B3032C179A49EE7'"
      Krikri::PluginHelpers::MysqlPrivileges.parse_show_grants_line(line)
        .must_equal(Grant.new("*.*", Set{"USAGE"}))
    end

    it "parses ALL PRIVILEGES on a single database" do
      line = "GRANT ALL PRIVILEGES ON `testdb1`.* TO `demo1`@`%`"
      Krikri::PluginHelpers::MysqlPrivileges.parse_show_grants_line(line)
        .must_equal(Grant.new("testdb1.*", Set{"ALL"}))
    end

    it "parses a comma-separated privilege list" do
      line = "GRANT SELECT, INSERT ON `testdb1`.* TO `demo2`@`%`"
      Krikri::PluginHelpers::MysqlPrivileges.parse_show_grants_line(line)
        .must_equal(Grant.new("testdb1.*", Set{"SELECT", "INSERT"}))
    end

    it "maps WITH GRANT OPTION to a GRANT pseudo-privilege" do
      line = "GRANT ALL PRIVILEGES ON *.* TO `demo3`@`%` IDENTIFIED BY PASSWORD '*X' WITH GRANT OPTION"
      Krikri::PluginHelpers::MysqlPrivileges.parse_show_grants_line(line)
        .must_equal(Grant.new("*.*", Set{"ALL", "GRANT"}))
    end

    it "strips backticks from the target" do
      line = "GRANT SELECT ON `testdb2`.* TO `demo2`@`%`"
      (Krikri::PluginHelpers::MysqlPrivileges.parse_show_grants_line(line) || raise "unexpected nil").target.must_equal("testdb2.*")
    end

    it "returns nil for a non-GRANT line" do
      Krikri::PluginHelpers::MysqlPrivileges.parse_show_grants_line("Grants for demo1@%").must_be_nil
    end
  end

  describe ".current_grants / .desired_grants" do
    include RaisesAssertion
    it "matches a real multi-database SHOW GRANTS result against the equivalent priv: spec" do
      show_grants = [
        "Grants for demo2@%",
        "GRANT USAGE ON *.* TO `demo2`@`%` IDENTIFIED BY PASSWORD '*14E65567ABDB5135D0CFD9A70B3032C179A49EE7'",
        "GRANT SELECT, INSERT ON `testdb1`.* TO `demo2`@`%`",
        "GRANT SELECT ON `testdb2`.* TO `demo2`@`%`",
      ]

      current = Krikri::PluginHelpers::MysqlPrivileges.current_grants(show_grants)
      desired = Krikri::PluginHelpers::MysqlPrivileges.desired_grants("testdb1.*:SELECT,INSERT/testdb2.*:SELECT")

      current.must_equal(desired)
    end

    it "matches the USAGE-only spec against the baseline-only SHOW GRANTS result (the fiaasco.mariadb warm-run case)" do
      show_grants = [
        "GRANT USAGE ON *.* TO `repro_user`@`localhost` IDENTIFIED BY PASSWORD '*BB6AC11BF1F51FF611DE717792B25EE9C005B129'",
      ]

      current = Krikri::PluginHelpers::MysqlPrivileges.current_grants(show_grants)
      desired = Krikri::PluginHelpers::MysqlPrivileges.desired_grants("*.*:USAGE")

      current.must_equal(desired)
    end

    it "adds the baseline *.* USAGE entry to a spec that doesn't mention *." do
      desired = Krikri::PluginHelpers::MysqlPrivileges.desired_grants("testdb.*:SELECT")
      desired.must_equal({
        "testdb.*" => Set{"SELECT"},
        "*.*"      => Set{"USAGE"},
      })
    end

    it "detects a real difference (extra privilege) as unequal" do
      show_grants = ["GRANT SELECT ON `testdb1`.* TO `demo`@`%`"]
      current = Krikri::PluginHelpers::MysqlPrivileges.current_grants(show_grants)
      desired = Krikri::PluginHelpers::MysqlPrivileges.desired_grants("testdb1.*:SELECT,INSERT")

      current.wont_equal(desired)
    end
  end

  describe ".plan_changes" do
    include RaisesAssertion
    ALIAS = Krikri::PluginHelpers::MysqlPrivileges

    it "ignores MariaDB's GRANT PROXY line" do
      ALIAS.parse_show_grants_line("GRANT PROXY ON ''@'%' TO 'root'@'localhost' WITH GRANT OPTION").must_be_nil
      ALIAS.current_grants(["GRANT ALL PRIVILEGES ON *.* TO `root`@`localhost` WITH GRANT OPTION", "GRANT PROXY ON ''@'%' TO 'root'@'localhost' WITH GRANT OPTION"]).keys.must_equal(["*.*"])
    end

    describe ".grant_parts" do
      it "keeps GRANT out of the privilege list" do
        ALIAS.grant_parts(["ALL", "GRANT"]).must_equal({"ALL", " WITH GRANT OPTION"})
      end

      it "turns a lone GRANT into USAGE with the clause" do
        ALIAS.grant_parts(["GRANT"]).must_equal({"USAGE", " WITH GRANT OPTION"})
      end

      it "leaves a plain list alone" do
        ALIAS.grant_parts(["INSERT", "SELECT"]).must_equal({"INSERT, SELECT", ""})
      end
    end

    it "plans nothing when current grants already match the spec" do
      current = {
        "*.*"      => Set{"USAGE"},
        "testdb.*" => Set{"SELECT", "INSERT"},
      }
      ALIAS.plan_changes(ALIAS.desired_grants("testdb.*:SELECT,INSERT"), current, false).must_equal([] of Krikri::PluginHelpers::MysqlPrivileges::Op)
    end

    it "plans nothing for the USAGE-only spec against the baseline USAGE row (warm-run idempotency)" do
      current = ALIAS.current_grants([
        "GRANT USAGE ON *.* TO `u`@`localhost` IDENTIFIED BY PASSWORD '*X'",
      ])
      ALIAS.plan_changes(ALIAS.desired_grants("*.*:USAGE"), current, false).must_equal([] of Krikri::PluginHelpers::MysqlPrivileges::Op)
      ALIAS.plan_changes(ALIAS.desired_grants("*.*:USAGE"), current, true).must_equal([] of Krikri::PluginHelpers::MysqlPrivileges::Op)
    end

    it "grants only the missing privileges on a shared target" do
      current = {"testdb.*" => Set{"SELECT"}, "*.*" => Set{"USAGE"}}
      ALIAS.plan_changes(ALIAS.desired_grants("testdb.*:SELECT,INSERT"), current, false)
        .must_equal([Krikri::PluginHelpers::MysqlPrivileges::Op.new(:grant, "testdb.*", ["INSERT"])])
    end

    it "never revokes with append_privs, only grants the missing privileges" do
      current = {"testdb.*" => Set{"SELECT", "DELETE"}, "*.*" => Set{"USAGE"}}
      ALIAS.plan_changes(ALIAS.desired_grants("testdb.*:SELECT,INSERT"), current, true)
        .must_equal([Krikri::PluginHelpers::MysqlPrivileges::Op.new(:grant, "testdb.*", ["INSERT"])])
    end

    it "revokes extra privileges on a shared target when replacing" do
      current = {"testdb.*" => Set{"SELECT", "DELETE"}, "*.*" => Set{"USAGE"}}
      ALIAS.plan_changes(ALIAS.desired_grants("testdb.*:SELECT"), current, false)
        .must_equal([Krikri::PluginHelpers::MysqlPrivileges::Op.new(:revoke, "testdb.*", ["DELETE"])])
    end

    it "revokes everything on targets the spec doesn't mention, only when replacing" do
      current = {"olddb.*" => Set{"SELECT"}, "*.*" => Set{"USAGE"}}
      replacing = ALIAS.plan_changes(ALIAS.desired_grants("newdb.*:SELECT"), current, false)
      replacing.must_equal([
        Krikri::PluginHelpers::MysqlPrivileges::Op.new(:revoke_all, "olddb.*", [] of String),
        Krikri::PluginHelpers::MysqlPrivileges::Op.new(:grant, "newdb.*", ["SELECT"]),
      ])

      appending = ALIAS.plan_changes(ALIAS.desired_grants("newdb.*:SELECT"), current, true)
      appending.must_equal([Krikri::PluginHelpers::MysqlPrivileges::Op.new(:grant, "newdb.*", ["SELECT"])])
    end

    it "revokes the grant option before the privileges on a dropped target that holds it" do
      current = {"olddb.*" => Set{"SELECT", "GRANT"}, "*.*" => Set{"USAGE"}}
      ALIAS.plan_changes(ALIAS.desired_grants("newdb.*:SELECT"), current, false)
        .must_equal([
          Krikri::PluginHelpers::MysqlPrivileges::Op.new(:revoke_grant_option, "olddb.*", [] of String),
          Krikri::PluginHelpers::MysqlPrivileges::Op.new(:revoke_all, "olddb.*", [] of String),
          Krikri::PluginHelpers::MysqlPrivileges::Op.new(:grant, "newdb.*", ["SELECT"]),
        ])
    end

    it "grants everything on a target the account has nothing on" do
      current = {"*.*" => Set{"USAGE"}}
      ALIAS.plan_changes(ALIAS.desired_grants("db.*:SELECT,INSERT"), current, false)
        .must_equal([Krikri::PluginHelpers::MysqlPrivileges::Op.new(:grant, "db.*", ["SELECT", "INSERT"])])
    end

    it "keeps only the grant option to revoke when ALL is granted" do
      current = {"db.*" => Set{"SELECT", "GRANT"}, "*.*" => Set{"USAGE"}}
      ALIAS.plan_changes(ALIAS.desired_grants("db.*:ALL"), current, false)
        .must_equal([Krikri::PluginHelpers::MysqlPrivileges::Op.new(:revoke_grant_option, "db.*", [] of String),
                     Krikri::PluginHelpers::MysqlPrivileges::Op.new(:grant, "db.*", ["ALL"])])
    end

    it "plans revoking the grant option when the spec drops WITH GRANT OPTION" do
      current = {"*.*" => Set{"USAGE", "GRANT"}}
      ALIAS.plan_changes(ALIAS.desired_grants("*.*:USAGE"), current, false)
        .must_equal([Krikri::PluginHelpers::MysqlPrivileges::Op.new(:revoke_grant_option, "*.*", [] of String)])
      ALIAS.plan_changes(ALIAS.desired_grants("*.*:USAGE"), current, true)
        .must_equal([] of Krikri::PluginHelpers::MysqlPrivileges::Op)
    end

    it "turns a GRANT-only spec into USAGE WITH GRANT OPTION" do
      current = {"*.*" => Set{"USAGE"}}
      # Replacing mode revokes the bare USAGE first and re-grants
      # GRANT+USAGE (WITH GRANT OPTION) - exactly what real's set diff
      # yields for a spec of '*.*:GRANT' against the baseline row.
      ALIAS.plan_changes(ALIAS.desired_grants("*.*:GRANT"), current, false)
        .must_equal([
          Krikri::PluginHelpers::MysqlPrivileges::Op.new(:revoke, "*.*", ["USAGE"]),
          Krikri::PluginHelpers::MysqlPrivileges::Op.new(:grant, "*.*", ["GRANT", "USAGE"]),
        ])
    end

    it "merges multiple GRANT lines for the same target" do
      current = ALIAS.current_grants([
        "GRANT USAGE ON *.* TO `u`@`%`",
        "GRANT SELECT ON *.* TO `u`@`%`",
        "GRANT INSERT ON *.* TO `u`@`%` WITH GRANT OPTION",
      ])
      current.must_equal({"*.*" => Set{"USAGE", "SELECT", "INSERT", "GRANT"}})
    end

    it "leaks real's grant_option flag from an earlier target onto a later revoke" do
      # SHOW GRANTS row order (dict insertion order): db1 holds the option,
      # db3 doesn't - real's grant_option variable is set by the db1
      # iteration and never reset, so the db3 revoke carries
      # REVOKE GRANT OPTION. On MySQL 8.4 the server rejects that
      # statement with 1141 and real fails the task (live-verified); 8.0
      # tolerates it. Sorted iteration would wrongly skip the option here.
      current = ALIAS.current_grants([
        "GRANT USAGE ON *.* TO `u`@`localhost`",
        "GRANT SELECT ON `db1`.* TO `u`@`localhost` WITH GRANT OPTION",
        "GRANT INSERT ON `db3`.* TO `u`@`localhost`",
      ])
      ALIAS.plan_changes(ALIAS.desired_grants("db1.*:SELECT"), current, false)
        .must_equal([
          Krikri::PluginHelpers::MysqlPrivileges::Op.new(:revoke_grant_option, "db3.*", [] of String),
          Krikri::PluginHelpers::MysqlPrivileges::Op.new(:revoke_all, "db3.*", [] of String),
          Krikri::PluginHelpers::MysqlPrivileges::Op.new(:revoke_grant_option, "db1.*", [] of String),
        ])
    end

    it "never plans the revoke-everything loop for an account named root" do
      current = {"olddb.*" => Set{"SELECT", "GRANT"}, "*.*" => Set{"USAGE"}}
      ALIAS.plan_changes(ALIAS.desired_grants("newdb.*:SELECT"), current, false, "root")
        .must_equal([Krikri::PluginHelpers::MysqlPrivileges::Op.new(:grant, "newdb.*", ["SELECT"])])
      # A target the spec adds is still granted for root (real's guard
      # only covers the revoke-everything loop); the shared targets
      # already match, so nothing else is planned.
      shared = {"db1.*" => Set{"SELECT"}, "*.*" => Set{"USAGE"}}
      ALIAS.plan_changes(ALIAS.desired_grants("db1.*:SELECT"), shared, false, "root")
        .must_equal([] of Krikri::PluginHelpers::MysqlPrivileges::Op)
    end
  end

  describe ".pylist" do
    it "renders Python's list repr shape" do
      Krikri::PluginHelpers::MysqlPrivileges.pylist(["GRANT", "USAGE"]).must_equal("['GRANT', 'USAGE']")
      Krikri::PluginHelpers::MysqlPrivileges.pylist([] of String).must_equal("[]")
    end
  end

  describe ".priv_change_msg" do
    ALIAS2 = Krikri::PluginHelpers::MysqlPrivileges

    it "returns nil when the grants already match" do
      current = {"*.*" => Set{"USAGE"}}
      ALIAS2.priv_change_msg(ALIAS2.desired_grants("*.*:USAGE"), current, false, "u").must_be_nil
    end

    it "says Privileges updated for a dropped target (replace mode)" do
      current = ALIAS2.current_grants([
        "GRANT USAGE ON *.* TO `u`@`localhost`",
        "GRANT SELECT ON `db1`.* TO `u`@`localhost`",
        "GRANT INSERT ON `db2`.* TO `u`@`localhost`",
      ])
      ALIAS2.priv_change_msg(ALIAS2.desired_grants("db1.*:SELECT"), current, false, "u")
        .must_equal("Privileges updated")
      ALIAS2.priv_change_msg(ALIAS2.desired_grants("db1.*:SELECT"), current, true, "u")
        .must_be_nil
    end

    it "says New privileges granted for a target the spec adds" do
      current = {"*.*" => Set{"USAGE"}}
      ALIAS2.priv_change_msg(ALIAS2.desired_grants("db1.*:SELECT"), current, false, "u")
        .must_equal("New privileges granted")
    end

    it "says the granted/revoked repr for a shared target diff" do
      current = {"*.*" => Set{"USAGE"}, "db1.*" => Set{"SELECT", "DELETE"}}
      ALIAS2.priv_change_msg(ALIAS2.desired_grants("db1.*:SELECT,INSERT"), current, false, "u")
        .must_equal("Privileges updated: granted ['INSERT'], revoked ['DELETE']")
      ALIAS2.priv_change_msg(ALIAS2.desired_grants("db1.*:SELECT,INSERT"), current, true, "u")
        .must_equal("Privileges updated: granted ['INSERT'], revoked []")
    end

    it "keeps GRANT in the repr lists and appends USAGE to a GRANT-only grant" do
      current = {"*.*" => Set{"USAGE"}}
      ALIAS2.priv_change_msg(ALIAS2.desired_grants("db1.*:ALL,GRANT"), current, false, "u")
        .must_equal("New privileges granted")
      current_opt = {"db1.*" => Set{"ALL"}, "*.*" => Set{"USAGE"}}
      ALIAS2.priv_change_msg(ALIAS2.desired_grants("db1.*:ALL,GRANT"), current_opt, false, "u")
        .must_equal("Privileges updated: granted ['GRANT', 'USAGE'], revoked []")
      current_with_opt = {"db1.*" => Set{"ALL", "GRANT"}, "*.*" => Set{"USAGE"}}
      ALIAS2.priv_change_msg(ALIAS2.desired_grants("db1.*:ALL"), current_with_opt, false, "u")
        .must_equal("Privileges updated: granted [], revoked ['GRANT']")
    end

    it "lets the intersect wording win over the revoke-all wording" do
      current = ALIAS2.current_grants([
        "GRANT USAGE ON *.* TO `u`@`localhost`",
        "GRANT APPLICATION_PASSWORD_ADMIN ON *.* TO `u`@`localhost`",
        "GRANT SELECT ON `mysql`.* TO `u`@`localhost`",
      ])
      ALIAS2.priv_change_msg(ALIAS2.desired_grants("*.*:USAGE"), current, false, "u")
        .must_equal("Privileges updated: granted [], revoked ['APPLICATION_PASSWORD_ADMIN']")
    end

    it "skips the revoke-all wording for an account named root" do
      current = {"olddb.*" => Set{"SELECT"}, "*.*" => Set{"USAGE"}}
      ALIAS2.priv_change_msg(ALIAS2.desired_grants("newdb.*:SELECT"), current, false, "root")
        .must_equal("New privileges granted")
    end
  end
end
