require 'pbkdf2'
require 'scrypt'
require 'openssl'
require 'digest'
require 'json'

module Laksa
  module Crypto
    class KeyStore
      T_PBKDF2 = 'pbkdf2' 
      T_SCRYPT = 'scrypt'

      def initialize
      end

      # encryptPrivateKey
      #
      # Encodes and encrypts an account in the format specified by
      # https://github.com/ethereum/wiki/wiki/Web3-Secret-Storage-Definition.
      # However, note that, in keeping with the hash function used by Zilliqa's
      # core protocol, the MAC is generated using sha256 instead of keccak.
      #
      # NOTE: only scrypt and pbkdf2 are supported.
      #
      # @param {string} private_key - hex-encoded private key
      # @param {string} password - a password used for encryption
      # @param {KDF} kdf_type - the key derivation function to be used
      def encrypt_private_key(private_key, password, kdf_type)
        address = KeyTool.get_address_from_private_key(private_key)

        iv = KeyTool.generate_random_bytes(16)
        salt = KeyTool.generate_random_bytes(32)

        case kdf_type
        when T_PBKDF2
          derived_key = PBKDF2.new(password: password, salt: salt, key_length: 32, iterations: 262144).value
        when T_SCRYPT
          derived_key = SCrypt::Engine.scrypt(password, salt, 8192, 8, 1, 32)
        end

        encrypt_key = derived_key[0..15]

        cipher = OpenSSL::Cipher.new('aes-128-ctr')
        cipher.encrypt
        cipher.iv = iv
        cipher.key = encrypt_key
        cipher.padding = 0
        
        ciphertext = cipher.update(Util.decode_hex(private_key)) + cipher.final

        mac = generate_mac(derived_key, ciphertext)

        datas = {address: address, 
          crypto: {
            cipher: 'aes-128-ctr', 
            cipherparams: {'iv': Util.encode_hex(iv)}, 
            ciphertext: Util.encode_hex(ciphertext), 
            kdf: kdf_type, 
            kdfparams: {n: 8192, c:262144, r:8, p:1, dklen: 32, salt: salt.bytes}, 
            mac: mac
          },
          id: SecureRandom.uuid, 
          version: 3
        }

        datas.to_json
      end

      # decrypt_private_key
      #
      # Recovers the private key from a keystore file using the given passphrase.
      #
      # @param {KeystoreV3} encrypt_json
      # @param {string} password
      def decrypt_private_key(encrypt_json, password)
        datas = JSON.parse(encrypt_json)

        ciphertext = Util.decode_hex(datas['crypto']['ciphertext'])
        iv = Util.decode_hex(datas['crypto']['cipherparams']['iv'])
        kdfparams = datas['crypto']['kdfparams']
        kdf_type = datas['crypto']['kdf']

        case kdf_type
        when T_PBKDF2
          derived_key = PBKDF2.new(password: password, salt: kdfparams['salt'].pack('c*'), key_length: kdfparams['dklen'], iterations: kdfparams['c']).value
        when T_SCRYPT
          derived_key = SCrypt::Engine.scrypt(password, kdfparams['salt'].pack('c*'), kdfparams['n'], kdfparams['r'], kdfparams['p'], kdfparams['dklen'])
        end

        encrypt_key = derived_key[0..15]

        mac = generate_mac(derived_key, ciphertext)
        
        raise 'Failed to decrypt.' if mac.casecmp(datas['crypto']['mac']) != 0

        cipher = OpenSSL::Cipher.new(datas['crypto']['cipher'])
        cipher.decrypt 
        cipher.iv = iv
        cipher.key = encrypt_key
        cipher.padding = 0
        
        private_key = cipher.update(ciphertext) + cipher.final

        return Util.encode_hex private_key
      end

      private
      def generate_mac(derived_key, ciphertext)
        Digest::SHA256.hexdigest(derived_key[16..32] + ciphertext)
      end
    end
  end
end