'use strict';
'require uci';
'require form';
'require network';

network.registerProtocol('ghoststream', {
    getI18n: function() {
        return _('GhostStream VPN');
    },

    getIfname: function() {
        return this._ubus('l3_device') || 'gs-%s'.format(this.sid);
    },

    getOpkgPackage: function() {
        return 'ghoststream';
    },

    isFloating: function() {
        return true;
    },

    isVirtual: function() {
        return true;
    },

    getDevices: function() {
        return null;
    },

    containsDevice: function(ifname) {
        return (network.getIfnameOf(ifname) == this.getIfname());
    },

    renderFormOptions: function(s) {
        var o;

        o = s.taboption('general', form.TextValue, 'connection_string', _('Connection String'),
            _('Base64-encoded connection string from the VPN server. Paste the full string here.'));
        o.rows = 3;
        o.rmempty = false;

        o = s.taboption('general', form.Value, 'mtu', _('MTU'),
            _('Maximum Transmission Unit for the tunnel interface.'));
        o.datatype = 'range(1280, 1500)';
        o.default = '1350';
        o.rmempty = true;
    }
});
